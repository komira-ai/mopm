//! Group publishing: a set of versions, one per package, declared up front,
//! uploaded, and made visible together (`createGroup`, `getGroup`,
//! `abortGroup`, `commitGroup`, `yankGroup` in spec/api/openapi.yaml).
//!
//! The wire shapes, status codes and error codes are the contract's. What the
//! fake chooses, as it does for single publishes:
//! - a group's id is a function of the caller and the declared set, so the same
//!   request is the same group (the fake's own derivation: a client does not
//!   compute these ids, unlike the hosted registry's documented ones);
//! - a group runs one stage per status poll, after the commit: `validating`,
//!   `committed`, `visible` (a rejected member ends it `rejected`, and nothing
//!   is visible); a yank or unyank moves one stage per poll too;
//! - a group is open for 12 hours of the fake's clock (`/_fake/clock`), and the
//!   next request that meets an open group past its deadline expires it;
//! - `/_fake/groups` turns group publishing off (`createGroup` then answers
//!   `route_not_found`, as a registry that has not enabled it does).
//! The fake keeps no rate counter for groups: a client tests a 429 with
//! `/_fake/fault`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const Ctx = api.Ctx;
const st = @import("state.zig");
const srcc = @import("source_commit.zig");
const resp = @import("resp.zig");
const Response = resp.Response;
const util = @import("util.zig");
const auth = @import("auth.zig");
const publish = @import("publish.zig");
const channel = @import("files.zig");

const subdirs = channel.subdirs;
/// A group is open for this long; the quarantine of the hosted registry keeps an upload for a day.
pub const deadline_secs: i64 = 12 * 60 * 60;
const max_members: usize = 500;
const max_files: usize = 20;
const max_file_bytes: i64 = 100_000_000;
const open_per_actor: usize = 5;
const supersede_max: usize = 3;
const max_reason: usize = 280;
const max_readme: usize = 65536;

// ---------------------------------------------------------------------------
// The request of createGroup
// ---------------------------------------------------------------------------

const ReqFile = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64 };
const ReqMember = struct { name: []const u8, version: []const u8, files: []ReqFile };
const Parsed = union(enum) { ok: []ReqMember, fail: Response };
/// What a create does when the caller's own open groups share a version with the new set (`on_overlap` of the body).
const OnOverlap = enum { supersede, refuse };
const OverlapOption = union(enum) { ok: OnOverlap, fail: Response };

/// The `on_overlap` option of the body: absent is `supersede`; a value that is not one of the two is invalid_request.
fn parseOnOverlap(ctx: *Ctx) Allocator.Error!OverlapOption {
    const obj = ctx.object() orelse return .{ .ok = .supersede };
    const v = obj.get("on_overlap") orelse return .{ .ok = .supersede };
    const text = switch (v) {
        .string => |s| s,
        else => "",
    };
    return .{ .ok = std.meta.stringToEnum(OnOverlap, text) orelse return .{ .fail = try resp.invalid(ctx.arena, "'on_overlap' is 'supersede' or 'refuse'") } };
}

fn isSha(s: []const u8) bool {
    return s.len == 64 and isHex(s);
}

/// The `GroupId` pattern: `grp_` and 32 lowercase hex digits.
fn isGroupId(s: []const u8) bool {
    return s.len == 36 and std.mem.startsWith(u8, s, "grp_") and isHex(s[4..]);
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

fn isSubdir(s: []const u8) bool {
    for (subdirs) |d| {
        if (std.mem.eql(u8, d, s)) return true;
    }
    return false;
}

fn memberLess(_: void, a: ReqMember, b: ReqMember) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn fileLess(_: void, a: ReqFile, b: ReqFile) bool {
    const o = std.mem.order(u8, a.subdir, b.subdir);
    if (o != .eq) return o == .lt;
    return std.mem.order(u8, a.filename, b.filename) == .lt;
}

fn parseRequest(ctx: *Ctx) Allocator.Error!Parsed {
    const a = ctx.arena;
    const obj = ctx.object() orelse return .{ .fail = try resp.invalid(a, "the body is not a JSON object") };
    const list = switch (obj.get("members") orelse return .{ .fail = try resp.invalid(a, "'members' is required") }) {
        .array => |l| l.items,
        else => return .{ .fail = try resp.invalid(a, "'members' must be an array") },
    };
    if (list.len < 1 or list.len > max_members) return .{ .fail = try resp.invalid(a, "'members' lists 1 to 500 members") };
    var out = std.ArrayList(ReqMember).init(a);
    for (list) |item| {
        const m = switch (item) {
            .object => |o| o,
            else => return .{ .fail = try resp.invalid(a, "a member is not a JSON object") },
        };
        const name = util.getStr(m, "name") orelse return .{ .fail = try resp.invalid(a, "a member needs a 'name' and a 'version', both strings") };
        const version = util.getStr(m, "version") orelse return .{ .fail = try resp.invalid(a, "a member needs a 'name' and a 'version', both strings") };
        if (!util.isName(name)) return .{ .fail = try resp.fail(a, .invalid_name, &.{.{ "name", name }}) };
        if (!util.isVersion(version)) return .{ .fail = try resp.fail(a, .invalid_version, &.{.{ "version", version }}) };
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen.name, name)) {
                const detail = try std.fmt.allocPrint(a, "'{s}' appears twice: a group has one version of each package", .{name});
                return .{ .fail = try resp.invalid(a, detail) };
            }
        }
        const files_value = switch (m.get("files") orelse std.json.Value{ .null = {} }) {
            .array => |l| l.items,
            else => return .{ .fail = try resp.invalid(a, "'files' must be an array") },
        };
        if (files_value.len < 1 or files_value.len > max_files) {
            const detail = try std.fmt.allocPrint(a, "'files' of '{s}' holds 1 to {d} files", .{ name, max_files });
            return .{ .fail = try resp.invalid(a, detail) };
        }
        var files = std.ArrayList(ReqFile).init(a);
        for (files_value) |fv| {
            const f = switch (fv) {
                .object => |o| o,
                else => return .{ .fail = try resp.invalid(a, "a file is not a JSON object") },
            };
            const subdir = util.getStr(f, "subdir") orelse return .{ .fail = try resp.invalid(a, "'subdir' must be a string") };
            if (!isSubdir(subdir)) return .{ .fail = try resp.invalid(a, "'subdir' is not a known subdir") };
            const filename = util.getStr(f, "filename") orelse return .{ .fail = try resp.invalid(a, "'filename' must be a string") };
            if (!std.mem.startsWith(u8, filename, "mojo-") or !std.mem.endsWith(u8, filename, ".conda")) {
                return .{ .fail = try resp.invalid(a, "'filename' is mojo-<name>-<version>-<build>.conda") };
            }
            const sha256 = util.getStr(f, "sha256") orelse return .{ .fail = try resp.invalid(a, "'sha256' must be a string") };
            if (!isSha(sha256)) return .{ .fail = try resp.invalid(a, "'sha256' is 64 lowercase hex digits") };
            const size = util.getInt(f, "size") orelse return .{ .fail = try resp.invalid(a, "'size' must be an integer") };
            if (size < 1) return .{ .fail = try resp.invalid(a, "'size' must be at least 1") };
            if (size > max_file_bytes) return .{ .fail = try resp.fail(a, .payload_too_large, &.{.{ "limit", "100000000" }}) };
            for (files.items) |other| {
                if (std.mem.eql(u8, other.subdir, subdir) and std.mem.eql(u8, other.filename, filename)) {
                    const detail = try std.fmt.allocPrint(a, "'{s}' lists the file {s}/{s} twice", .{ name, subdir, filename });
                    return .{ .fail = try resp.invalid(a, detail) };
                }
            }
            try files.append(.{ .subdir = subdir, .filename = filename, .sha256 = sha256, .size = @intCast(size) });
        }
        std.mem.sort(ReqFile, files.items, {}, fileLess);
        try out.append(.{ .name = name, .version = version, .files = files.items });
    }
    std.mem.sort(ReqMember, out.items, {}, memberLess);
    return .{ .ok = out.items };
}

/// `grp_` and 32 hex digits: a hash of the caller and the declared set.
fn groupId(arena: Allocator, handle: []const u8, members: []const ReqMember) Allocator.Error![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(handle);
    h.update("\n");
    for (members) |m| {
        h.update(m.name);
        h.update("\n");
        h.update(m.version);
        h.update("\n");
        for (m.files) |f| {
            const line = try std.fmt.allocPrint(arena, "{s}/{s}:{s}:{d}\n", .{ f.subdir, f.filename, f.sha256, f.size });
            h.update(line);
        }
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.allocPrint(arena, "grp_{s}", .{std.fmt.fmtSliceHexLower(digest[0..16])});
}

/// The id of the upload that carries one declared file; the same on every call, so a resume finds it.
fn uploadId(arena: Allocator, gid: []const u8, m: ReqMember, f: ReqFile) Allocator.Error![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const line = try std.fmt.allocPrint(arena, "{s}|{s}|{s}|{s}/{s}|{s}|{d}", .{ gid, m.name, m.version, f.subdir, f.filename, f.sha256, f.size });
    h.update(line);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.allocPrint(arena, "upl_{s}", .{std.fmt.fmtSliceHexLower(digest[0..12])});
}

// ---------------------------------------------------------------------------
// Who may do what
// ---------------------------------------------------------------------------

const Caller = union(enum) { ok: *st.Token, fail: Response };

/// The token behind the request, for the routes that act on a group that exists. A login's session token is not one.
fn caller(ctx: *Ctx) anyerror!Caller {
    const t = switch (try auth.authenticate(ctx)) {
        .ok => |t| t,
        .fail => |r| return .{ .fail = r },
    };
    if (t.kind == .session) {
        return .{ .fail = try resp.fail(ctx.arena, .scope_missing, &.{ .{ "scope", "publish" }, .{ "name", "this group" } }) };
    }
    return .{ .ok = t };
}

/// Whether an API token has one of `scopes` for package `name`.
fn tokenCovers(t: *const st.Token, name: []const u8, scopes: []const st.Scope) bool {
    if (t.kind != .api) return false;
    var has_scope = false;
    for (t.scopes) |sc| {
        if (std.mem.indexOfScalar(st.Scope, scopes, sc) != null) has_scope = true;
    }
    if (!has_scope) return false;
    for (t.packages) |p| {
        if (std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

/// Whether the token of a `packages` exchange names `name` at exactly `version`.
fn oidcSetCovers(t: *const st.Token, name: []const u8, version: []const u8) bool {
    if (t.kind != .oidc) return false;
    for (t.oidc_set) |nv| {
        if (std.mem.eql(u8, nv.name, name) and std.mem.eql(u8, nv.version, version)) return true;
    }
    return false;
}

fn findGroup(s: *st.State, id: []const u8) ?*st.Group {
    for (s.groups.items) |g| {
        if (std.mem.eql(u8, g.id, id)) return g;
    }
    return null;
}

/// An open group past its deadline is expired by the request that meets it.
fn expireIfDue(s: *st.State, g: *st.Group) void {
    if (g.status == .open and s.now() >= g.deadline_at) g.status = .expired;
}

fn ownsAll(g: *const st.Group, user: *const st.User) bool {
    for (g.members) |m| {
        if (!m.package.isOwner(user)) return false;
    }
    return g.members.len > 0;
}

const Loaded = union(enum) { ok: *st.Group, fail: Response };

/// The group `id` as `t` may see it: its creator, or an owner of every package in it. Anyone else gets `group_not_found`.
fn load(ctx: *Ctx, t: *const st.Token, id: []const u8) anyerror!Loaded {
    const g = (if (isGroupId(id)) findGroup(ctx.state, id) else null) orelse return .{ .fail = try resp.fail(ctx.arena, .group_not_found, &.{}) };
    if (g.user != t.user and !ownsAll(g, t.user)) return .{ .fail = try resp.fail(ctx.arena, .group_not_found, &.{}) };
    expireIfDue(ctx.state, g);
    return .{ .ok = g };
}

// ---------------------------------------------------------------------------
// The answers
// ---------------------------------------------------------------------------

fn jsonOmitting(arena: Allocator, status: std.http.Status, value: anytype) Allocator.Error!Response {
    var buf = std.ArrayList(u8).init(arena);
    std.json.stringify(value, .{ .emit_null_optional_fields = false }, buf.writer()) catch return error.OutOfMemory;
    return .{ .status = status, .body = buf.items };
}

/// One declared file of a member, as `getGroup` shows it. `uploaded` is set only while the group is open.
const FileView = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64, uploaded: ?bool = null };
/// `files` is set on the answer of `getGroup` only.
const MemberView = struct { name: []const u8, version: []const u8, state: []const u8, files: ?[]const FileView = null };
const FailureView = struct { code: []const u8, message: []const u8, member: ?[]const u8 = null };
const YankView = struct { state: []const u8, reason: []const u8, requested_at: []const u8, yanked_members: usize };
const GroupView = struct {
    group_id: []const u8,
    status: []const u8,
    attempt: u32,
    created_at: []const u8,
    deadline_at: []const u8,
    committed_at: ?[]const u8 = null,
    failure: ?FailureView = null,
    member_count: usize,
    yank: ?YankView = null,
    members: []const MemberView,
};

fn memberState(g: *const st.Group, m: st.GroupMember) []const u8 {
    return switch (g.status) {
        .visible => if (m.row.state == .yanked) "yanked" else "published",
        .committed => "staged",
        else => "reserved",
    };
}

/// Whether the member's row is still this group's: the group holds the number, or published the version. A row another group or a
/// single publish took after this group ended is not.
fn holdsRow(g: *const st.Group, m: st.GroupMember) bool {
    if (m.row.group) |held| if (held == g) return true;
    const id = m.row.group_id orelse return false;
    return std.mem.eql(u8, id, g.id);
}

/// The declared files of one member, with `uploaded` while the group is open; empty when the row is no longer the group's.
fn filesView(arena: Allocator, g: *const st.Group, m: st.GroupMember) Allocator.Error![]const FileView {
    if (!holdsRow(g, m)) return &.{};
    const n = @min(m.files.len, max_files);
    const out = try arena.alloc(FileView, n);
    for (m.files[0..n], out) |f, *o| {
        o.* = .{ .subdir = f.subdir, .filename = f.filename, .sha256 = f.sha256, .size = f.size };
        if (g.status == .open) o.uploaded = f.upload.path != null;
    }
    return out;
}

/// The group as the answers show it; `with_files` is `getGroup`'s, for which each member lists its files.
fn view(arena: Allocator, g: *const st.Group, with_files: bool) Allocator.Error!GroupView {
    var members = std.ArrayList(MemberView).init(arena);
    var yanked: usize = 0;
    for (g.members, 0..) |m, i| {
        const files: ?[]const FileView = if (with_files and i < max_members) try filesView(arena, g, m) else if (with_files) &.{} else null;
        try members.append(.{ .name = m.package.name, .version = m.version, .state = memberState(g, m), .files = files });
        if (m.yanked_by_group) yanked += 1;
    }
    return .{
        .group_id = g.id,
        .status = @tagName(g.status),
        .attempt = g.attempt,
        .created_at = try util.rfc3339(arena, g.created_at),
        .deadline_at = try util.rfc3339(arena, g.deadline_at),
        .committed_at = if (g.committed_at != 0) try util.rfc3339(arena, g.committed_at) else null,
        .failure = if (g.failure) |f| .{ .code = f.code, .message = f.message, .member = f.member } else null,
        .member_count = g.members.len,
        .yank = if (g.yank) |y| .{
            .state = @tagName(y.state),
            .reason = y.reason,
            .requested_at = try util.rfc3339(arena, y.requested_at),
            .yanked_members = yanked,
        } else null,
        .members = members.items,
    };
}

const PutHeaders = struct {
    @"content-length": []const u8,
    @"x-amz-checksum-sha256": []const u8,
};
const FileAnswer = struct {
    subdir: []const u8,
    filename: []const u8,
    upload_id: []const u8,
    uploaded: bool,
    put_url: ?[]const u8 = null,
    put_headers: ?PutHeaders = null,
    expires_at: ?[]const u8 = null,
};
const MemberAnswer = struct { name: []const u8, version: []const u8, action: []const u8, files: []const FileAnswer };
const CreateAnswer = struct {
    group_id: []const u8,
    status: []const u8,
    attempt: u32,
    deadline_at: []const u8,
    /// The caller's own groups this call ended; absent when it ended none.
    superseded: ?[]const []const u8 = null,
    members: []const MemberAnswer,
};

/// What a group in a state past reserving needs of each member: nothing.
fn unchangedAnswer(arena: Allocator, g: *const st.Group, code: std.http.Status) Allocator.Error!Response {
    var members = std.ArrayList(MemberAnswer).init(arena);
    for (g.members) |m| try members.append(.{ .name = m.package.name, .version = m.version, .action = "skip_identical", .files = &.{} });
    return jsonOmitting(arena, code, CreateAnswer{
        .group_id = g.id,
        .status = @tagName(g.status),
        .attempt = g.attempt,
        .deadline_at = try util.rfc3339(arena, g.deadline_at),
        .members = members.items,
    });
}

/// The upload of one file: a fresh URL unless the bytes are in storage.
fn fileAnswer(ctx: *Ctx, f: st.GroupFile) Allocator.Error!FileAnswer {
    const s = ctx.state;
    const base = FileAnswer{ .subdir = f.subdir, .filename = f.filename, .upload_id = f.upload.id, .uploaded = f.upload.path != null };
    if (f.upload.path != null) return base;
    f.upload.expires_at = s.now() + st.upload_secs;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, f.sha256) catch unreachable;
    var b64: [44]u8 = undefined;
    var out = base;
    out.put_url = try std.fmt.allocPrint(ctx.arena, "{s}/_fake/upload/{s}", .{ s.base_url, f.upload.id });
    out.put_headers = .{
        .@"content-length" = try std.fmt.allocPrint(ctx.arena, "{d}", .{f.size}),
        .@"x-amz-checksum-sha256" = try ctx.arena.dupe(u8, std.base64.standard.Encoder.encode(&b64, &digest)),
    };
    out.expires_at = try util.rfc3339(ctx.arena, f.upload.expires_at);
    return out;
}

// ---------------------------------------------------------------------------
// createGroup
// ---------------------------------------------------------------------------

/// What holds the number of a declared member.
const Held = union(enum) { free, mine, adopt, fail: Response };

fn rowHash(v: *const st.Version) []const u8 {
    if (v.files.len > 0) return v.files[0].sha256;
    return v.manifest_sha256;
}

fn contains(list: []const *st.Group, g: *const st.Group) bool {
    for (list) |x| {
        if (x == g) return true;
    }
    return false;
}

fn holder(ctx: *Ctx, gid: []const u8, m: ReqMember, p: *st.Package, superseding: []const *st.Group) Allocator.Error!Held {
    const row = publish.findVersion(p, m.version) orelse return .free;
    if (row.state != .pending or row.group == null) {
        return .{ .fail = try resp.fail(ctx.arena, .version_exists, &.{ .{ "name", p.name }, .{ "version", row.version }, .{ "sha256", rowHash(row) } }) };
    }
    const h = row.group.?;
    expireIfDue(ctx.state, h);
    if (std.mem.eql(u8, h.id, gid)) return .mine;
    if (st.groupIsDead(h.status) or contains(superseding, h)) return .adopt;
    const detail = try std.fmt.allocPrint(ctx.arena, "{s} {s} is held by group {s}, which is {s}", .{ p.name, m.version, h.id, @tagName(h.status) });
    return .{ .fail = try resp.conflict(ctx.arena, .number_held, detail) };
}

fn sameMember(g: *const st.Group, m: ReqMember) bool {
    for (g.members) |x| {
        if (std.mem.eql(u8, x.package.name, m.name) and std.mem.eql(u8, x.version, m.version)) return true;
    }
    return false;
}

pub fn createGroup(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const s = ctx.state;
    if (!s.groups_enabled) return resp.fail(ctx.arena, .route_not_found, &.{});
    if (s.read_only) return resp.fail(ctx.arena, .read_only_mode, &.{});
    const t = switch (try auth.authenticate(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const members = switch (try parseRequest(ctx)) {
        .ok => |m| m,
        .fail => |r| return r,
    };
    const on_overlap = switch (try parseOnOverlap(ctx)) {
        .ok => |o| o,
        .fail => |r| return r,
    };
    // A group is made with an API token that may publish every member, or with the token of a `packages` exchange that names
    // every member at its version. The token of the single-package exchange is for one version of one package: no group.
    for (members) |m| {
        if (!(tokenCovers(t, m.name, &.{.publish}) or oidcSetCovers(t, m.name, m.version))) {
            return resp.fail(ctx.arena, .scope_missing, &.{ .{ "scope", "publish" }, .{ "name", m.name } });
        }
    }
    var packages = std.ArrayList(*st.Package).init(ctx.arena);
    for (members) |m| {
        const p = s.packageByName(m.name) orelse return resp.fail(ctx.arena, .package_not_found, &.{.{ "name", m.name }});
        if (!p.isOwner(t.user)) return resp.fail(ctx.arena, .not_owner, &.{.{ "name", m.name }});
        try packages.append(p);
    }
    const gid = try groupId(ctx.arena, t.user.handle, members);

    var group = findGroup(s, gid);
    if (group) |g| {
        expireIfDue(s, g);
        switch (g.status) {
            .validating, .committed, .visible => return unchangedAnswer(ctx.arena, g, .ok),
            .failed => {
                const detail = try std.fmt.allocPrint(ctx.arena, "group {s} failed after its files were copied, and its version numbers are burned; publish a new version of each package", .{gid});
                return resp.conflict(ctx.arena, .group_failed, detail);
            },
            else => {},
        }
    }

    var created = false;
    var superseded: []const []const u8 = &.{};
    if (group == null or st.groupIsDead(group.?.status)) {
        const superseding = switch (try takeSlot(ctx, t.user, gid, members, on_overlap)) {
            .ok => |l| l,
            .fail => |r| return r,
        };
        // Every number must be free for the group before anything is written.
        for (members, packages.items) |m, p| {
            switch (try holder(ctx, gid, m, p, superseding)) {
                .fail => |r| return r,
                else => {},
            }
            var add: u64 = 0;
            for (m.files) |f| add += f.size;
            if (add + liveBytes(p) > s.project_bytes) {
                return resp.fail(ctx.arena, .limit_exceeded, &.{
                    .{ "name", p.name },
                    .{ "limit", try std.fmt.allocPrint(ctx.arena, "{d}", .{s.project_bytes}) },
                    .{ "remaining", try std.fmt.allocPrint(ctx.arena, "{d}", .{s.project_bytes -| liveBytes(p)}) },
                });
            }
        }
        var ended = std.ArrayList([]const u8).init(ctx.arena);
        for (superseding) |o| {
            o.status = .superseded;
            try ended.append(o.id);
        }
        superseded = ended.items;
        const deadline = s.now() + deadline_secs;
        if (group) |g| {
            g.attempt += 1;
            g.status = .open;
            g.deadline_at = deadline;
            g.committed_at = 0;
            g.failure = null;
            g.commit_hash = "";
            g.yank = null;
        } else {
            const made = try s.add(st.Group, &s.groups, .{
                .id = try s.alloc.dupe(u8, gid),
                .user = t.user,
                .created_at = s.now(),
                .deadline_at = deadline,
                .members = &.{},
            });
            group = made;
        }
        created = true;
    }
    const g = group.?;
    return reserve(ctx, g, members, packages.items, created, superseded);
}

fn liveBytes(p: *const st.Package) u64 {
    var used: u64 = 0;
    for (p.versions.items) |v| {
        if (v.state != .published and v.state != .yanked) continue;
        for (v.files) |f| used += f.size;
    }
    return used;
}

const Slot = union(enum) { ok: []const *st.Group, fail: Response };

/// A place among the caller's open groups. The ones that share a member with this group are superseded by it.
fn takeSlot(ctx: *Ctx, user: *const st.User, gid: []const u8, members: []const ReqMember, on_overlap: OnOverlap) Allocator.Error!Slot {
    const s = ctx.state;
    var overlapping = std.ArrayList(*st.Group).init(ctx.arena);
    var open: usize = 0;
    for (s.groups.items) |o| {
        if (o.user != user or std.mem.eql(u8, o.id, gid)) continue;
        expireIfDue(s, o);
        if (o.status != .open) continue;
        open += 1;
        for (members) |m| {
            if (sameMember(o, m)) {
                try overlapping.append(o);
                break;
            }
        }
    }
    if (on_overlap == .refuse and overlapping.items.len > 0) {
        var ids = std.ArrayList(u8).init(ctx.arena);
        for (overlapping.items, 0..) |o, i| {
            if (i > 0) try ids.appendSlice(", ");
            try ids.appendSlice(o.id);
        }
        const one = overlapping.items.len == 1;
        const plural: []const u8 = if (one) "" else "s";
        const them: []const u8 = if (one) "it" else "them";
        const detail = try std.fmt.allocPrint(ctx.arena, "it shares versions with your open group{s} {s}, and on_overlap is refuse; abort {s} first, or send on_overlap supersede", .{ plural, ids.items, them });
        return .{ .fail = try resp.conflict(ctx.arena, .overlap_refused, detail) };
    }
    if (overlapping.items.len > supersede_max) {
        const detail = try std.fmt.allocPrint(ctx.arena, "it shares versions with {d} of your open groups, and one create supersedes at most {d}; abort some first", .{ overlapping.items.len, supersede_max });
        return .{ .fail = try resp.conflict(ctx.arena, .supersede_cap, detail) };
    }
    if (open - overlapping.items.len >= open_per_actor) {
        const detail = try std.fmt.allocPrint(ctx.arena, "you already have {d} open groups, and at most {d} may be open; abort one first", .{ open - overlapping.items.len, open_per_actor });
        return .{ .fail = try resp.conflict(ctx.arena, .open_cap, detail) };
    }
    return .{ .ok = overlapping.items };
}

/// Writes the members' rows and uploads for a group that is new, opened again, or open and asked for again; answers with each file's URL.
fn reserve(ctx: *Ctx, g: *st.Group, members: []const ReqMember, packages: []*st.Package, fresh: bool, superseded: []const []const u8) anyerror!Response {
    const s = ctx.state;
    var stored = std.ArrayList(st.GroupMember).init(s.alloc);
    var answers = std.ArrayList(MemberAnswer).init(ctx.arena);
    for (members, packages) |m, p| {
        var declared = std.ArrayList(st.File).init(s.alloc);
        var uploads = std.ArrayList(st.GroupFile).init(s.alloc);
        for (m.files) |f| {
            const id = try uploadId(ctx.arena, g.id, m, f);
            const u = findUpload(s, id) orelse try s.add(st.Upload, &s.uploads, .{
                .id = try s.alloc.dupe(u8, id),
                .user = g.user,
                .package = p.name,
                .version = try s.alloc.dupe(u8, m.version),
                .subdir = try s.alloc.dupe(u8, f.subdir),
                .filename = try s.alloc.dupe(u8, f.filename),
                .sha256 = try s.alloc.dupe(u8, f.sha256),
                .size = f.size,
                .expires_at = s.now() + st.upload_secs,
            });
            try uploads.append(.{ .subdir = u.subdir, .filename = u.filename, .sha256 = u.sha256, .size = u.size, .upload = u });
            // The row keeps the upload's copies of the strings: the request's own die with its arena.
            try declared.append(.{ .subdir = u.subdir, .filename = u.filename, .sha256 = u.sha256, .size = u.size, .path = "" });
        }
        var action: []const u8 = "join";
        const row = if (publish.findVersion(p, m.version)) |r| r else blk: {
            action = "new";
            break :blk try s.add(st.Version, &p.versions, .{
                .package = p,
                .version = try s.alloc.dupe(u8, m.version),
                .files = &.{},
                .manifest_sha256 = "",
                .published_by = g.user.handle,
            });
        };
        if (fresh) {
            row.group = g;
            row.files = declared.items;
            row.manifest_sha256 = uploads.items[0].sha256;
        }
        try stored.append(.{ .package = p, .version = row.version, .files = uploads.items, .row = row });
        var files = std.ArrayList(FileAnswer).init(ctx.arena);
        for (uploads.items) |gf| try files.append(try fileAnswer(ctx, gf));
        try answers.append(.{ .name = p.name, .version = row.version, .action = action, .files = files.items });
    }
    if (fresh) g.members = stored.items;
    return jsonOmitting(ctx.arena, if (fresh) .created else .ok, CreateAnswer{
        .group_id = g.id,
        .status = @tagName(g.status),
        .attempt = g.attempt,
        .deadline_at = try util.rfc3339(ctx.arena, g.deadline_at),
        .superseded = if (superseded.len > 0) superseded else null,
        .members = answers.items,
    });
}

fn findUpload(s: *st.State, id: []const u8) ?*st.Upload {
    for (s.uploads.items) |u| {
        if (std.mem.eql(u8, u.id, id)) return u;
    }
    return null;
}

// ---------------------------------------------------------------------------
// getGroup and abortGroup
// ---------------------------------------------------------------------------

pub fn getGroup(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const t = switch (try caller(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const g = switch (try load(ctx, t, params[0])) {
        .ok => |g| g,
        .fail => |r| return r,
    };
    // As a single publish does, the group shows the stage it is in and moves one stage for the next poll.
    const shown = try view(ctx.arena, g, true);
    try advance(ctx, g);
    return jsonOmitting(ctx.arena, .ok, shown);
}

pub fn abortGroup(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const t = switch (try caller(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const g = switch (try load(ctx, t, params[0])) {
        .ok => |g| g,
        .fail => |r| return r,
    };
    if (g.status == .open) g.status = .aborted;
    if (g.status != .aborted) {
        return resp.fail(ctx.arena, .group_not_open, &.{ .{ "group_id", g.id }, .{ "status", @tagName(g.status) } });
    }
    return jsonOmitting(ctx.arena, .ok, try view(ctx.arena, g, false));
}

// ---------------------------------------------------------------------------
// The stages after the commit, and after a yank
// ---------------------------------------------------------------------------

/// The rejection the fake finds in a member's files, or null: a file name that does not name the package and version,
/// or bytes that start with `REJECT:<code>` (as for a single publish).
fn rejectionOf(ctx: *Ctx, m: st.GroupMember) anyerror!?[]const u8 {
    const want = try std.fmt.allocPrint(ctx.arena, "mojo-{s}-{s}-", .{ m.package.name, m.version });
    var dir = try std.fs.cwd().openDir(ctx.state.dir, .{});
    defer dir.close();
    for (m.files) |f| {
        if (!std.mem.startsWith(u8, f.filename, want)) return "filename_mismatch";
        var head: [64]u8 = undefined;
        const file = try dir.openFile(f.upload.path.?, .{});
        defer file.close();
        const n = try file.readAll(&head);
        const marker = "REJECT:";
        if (std.mem.startsWith(u8, head[0..n], marker)) {
            const rest = head[marker.len..n];
            for (publish.rejection_codes) |code| {
                if (std.mem.startsWith(u8, rest, code)) return code;
            }
        }
    }
    return null;
}

fn advance(ctx: *Ctx, g: *st.Group) anyerror!void {
    const s = ctx.state;
    switch (g.status) {
        .validating => {
            for (g.members) |m| {
                const code = (try rejectionOf(ctx, m)) orelse continue;
                g.status = .rejected;
                g.failure = .{
                    .code = code,
                    .message = try std.fmt.allocPrint(s.alloc, "the fake registry rejected {s}: {s}", .{ m.package.name, code }),
                    .member = m.package.name,
                };
                return;
            }
            g.status = .committed;
            g.committed_at = s.now();
        },
        .committed => {
            for (g.members) |m| {
                const files = try s.alloc.alloc(st.File, m.files.len);
                for (m.files, files) |gf, *out| {
                    out.* = .{ .subdir = gf.subdir, .filename = gf.filename, .sha256 = gf.sha256, .size = gf.size, .path = gf.upload.path.? };
                }
                m.row.files = files;
                m.row.state = .published;
                m.row.published_at = g.committed_at;
                m.row.group = null;
                m.row.group_id = g.id;
                m.row.source_commit = m.source_commit;
                m.package.state = .active;
                m.package.updated_at = g.committed_at;
                try channel.addFiles(s, m.row);
            }
            g.status = .visible;
            try channel.rewrite(ctx.arena, s);
        },
        .visible => try advanceYank(ctx, g),
        else => {},
    }
}

fn advanceYank(ctx: *Ctx, g: *st.Group) anyerror!void {
    const s = ctx.state;
    const y = g.yank orelse return;
    switch (y.state) {
        .yanking => {
            for (g.members) |*m| {
                if (m.row.state != .published) continue;
                m.row.state = .yanked;
                m.row.yank_reason = y.reason;
                m.yanked_by_group = true;
                m.package.updated_at = s.now();
            }
            g.yank.?.state = .yanked;
            try channel.rewrite(ctx.arena, s);
        },
        .unyanking => {
            for (g.members) |*m| {
                if (!m.yanked_by_group) continue;
                if (m.row.state == .yanked) {
                    m.row.state = .published;
                    m.row.yank_reason = null;
                    m.package.updated_at = s.now();
                }
            }
            g.yank.?.state = .restored;
            try channel.rewrite(ctx.arena, s);
        },
        .yanked, .restored => {},
    }
}

// ---------------------------------------------------------------------------
// commitGroup
// ---------------------------------------------------------------------------

const Commit = union(enum) { ok: []const u8, fail: Response };

/// Checks the commit request against the group's members and returns what names it: a string that is the same for the same request.
fn parseCommit(ctx: *Ctx, g: *const st.Group, manifests: []?[]const u8, sources: []?[]const u8) Allocator.Error!Commit {
    const a = ctx.arena;
    const obj = ctx.object() orelse return .{ .fail = try resp.invalid(a, "the body is not a JSON object") };
    const list = switch (obj.get("members") orelse return .{ .fail = try resp.invalid(a, "'members' lists the manifest of each member of the group") }) {
        .array => |l| l.items,
        else => return .{ .fail = try resp.invalid(a, "'members' lists the manifest of each member of the group") },
    };
    var hash = std.ArrayList(u8).init(a);
    for (manifests) |*slot| slot.* = null;
    @memset(sources, null);
    var listed = std.ArrayList([]const u8).init(a);
    for (list) |item| {
        const m = switch (item) {
            .object => |o| o,
            else => return .{ .fail = try resp.invalid(a, "a member is not a JSON object") },
        };
        const name = util.getStr(m, "name") orelse return .{ .fail = try resp.invalid(a, "a member needs a 'name'") };
        for (listed.items) |seen| {
            if (std.mem.eql(u8, seen, name)) return .{ .fail = try resp.invalid(a, try std.fmt.allocPrint(a, "'{s}' appears twice", .{name})) };
        }
        try listed.append(name);
        // Optional: absent is "", which the fake keeps as it is (it opens no archive, so it has no hash of its own to put in its place:
        // a published member's `manifest_sha256` is its first file's sha256 whatever the request said, as it always was).
        const given: ?[]const u8 = if (m.get("manifest_sha256")) |v| switch (v) {
            .string => |x| x,
            else => "",
        } else null;
        if (given) |x| if (!isSha(x)) return .{ .fail = try resp.invalid(a, try std.fmt.allocPrint(a, "'manifest_sha256' of '{s}' is 64 lowercase hex digits", .{name})) };
        const sha = given orelse "";
        const source: ?[]const u8 = switch (srcc.parse(m)) {
            .absent => null,
            .ok => |x| x,
            .invalid => return .{ .fail = try resp.invalid(a, try srcc.refusal(a, try std.fmt.allocPrint(a, " of '{s}'", .{name}))) },
        };
        var found = false;
        for (g.members, 0..) |gm, i| {
            if (std.mem.eql(u8, gm.package.name, name)) {
                manifests[i] = sha;
                sources[i] = source;
                found = true;
            }
        }
        if (!found) return .{ .fail = try resp.invalid(a, try std.fmt.allocPrint(a, "'{s}' is not a member of the group", .{name})) };
        const display = [_][]const u8{ "description", "license", "readme" };
        var shown_text = std.ArrayList(u8).init(a);
        for (display) |key| {
            if (m.get(key)) |v| {
                switch (v) {
                    .string => |text| {
                        if (text.len == 0 or (std.mem.eql(u8, key, "readme") and text.len > max_readme) or (!std.mem.eql(u8, key, "readme") and text.len > 512)) {
                            return .{ .fail = try resp.invalid(a, try std.fmt.allocPrint(a, "'{s}' of '{s}' is empty or too long", .{ key, name })) };
                        }
                        try shown_text.appendSlice(text);
                    },
                    else => return .{ .fail = try resp.invalid(a, try std.fmt.allocPrint(a, "'{s}' of '{s}' must be a string", .{ key, name })) },
                }
            }
            try shown_text.append(0);
        }
        try hash.writer().print("{s}:{s}:{s}:{s}\n", .{ name, sha, shown_text.items, source orelse "" });
    }
    for (g.members, manifests) |gm, got| {
        if (got == null) return .{ .fail = try resp.invalid(a, try std.fmt.allocPrint(a, "'members' has no entry for '{s}', a member of the group", .{gm.package.name})) };
    }
    // The same request, in any member order, has the same hash.
    var digest: [32]u8 = undefined;
    var lines = std.mem.splitScalar(u8, hash.items, '\n');
    var sorted = std.ArrayList([]const u8).init(a);
    while (lines.next()) |l| try sorted.append(l);
    std.mem.sort([]const u8, sorted.items, {}, st.lessString);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (sorted.items) |l| {
        h.update(l);
        h.update("\n");
    }
    h.final(&digest);
    return .{ .ok = try std.fmt.allocPrint(a, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) };
}

const CommitAnswer = struct { group_id: []const u8, status: []const u8, attempt: u32, status_url: []const u8 };

pub fn commitGroup(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const s = ctx.state;
    s.clock_offset += s.clock_jump_on_commit;
    s.clock_jump_on_commit = 0;
    if (s.read_only) return resp.fail(ctx.arena, .read_only_mode, &.{});
    const t = switch (try caller(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const g = switch (try load(ctx, t, params[0])) {
        .ok => |g| g,
        .fail => |r| return r,
    };
    const manifests = try ctx.arena.alloc(?[]const u8, g.members.len);
    const sources = try ctx.arena.alloc(?[]const u8, g.members.len);
    const hash = switch (try parseCommit(ctx, g, manifests, sources)) {
        .ok => |h| h,
        .fail => |r| return r,
    };
    const answer = CommitAnswer{
        .group_id = g.id,
        .status = @tagName(g.status),
        .attempt = g.attempt,
        .status_url = try std.fmt.allocPrint(ctx.arena, "/api/v1/groups/{s}", .{g.id}),
    };
    switch (g.status) {
        .validating, .committed, .visible => {
            if (!std.mem.eql(u8, g.commit_hash, hash)) {
                const detail = try std.fmt.allocPrint(ctx.arena, "group {s} is {s} on another commit request", .{ g.id, @tagName(g.status) });
                return resp.fail(ctx.arena, .group_commit_refused, &.{.{ "detail", detail }});
            }
            return resp.json(ctx.arena, if (g.status == .validating) .accepted else .ok, answer);
        },
        .open => {},
        else => {
            const detail = if (g.status == .expired)
                try std.fmt.allocPrint(ctx.arena, "group {s} expired at {s}", .{ g.id, try util.rfc3339(ctx.arena, g.deadline_at) })
            else
                try std.fmt.allocPrint(ctx.arena, "group {s} is {s}", .{ g.id, @tagName(g.status) });
            return resp.fail(ctx.arena, .group_commit_refused, &.{.{ "detail", detail }});
        },
    }
    for (g.members) |m| {
        for (m.files) |f| {
            if (f.upload.path == null) {
                const detail = try std.fmt.allocPrint(ctx.arena, "{s} of '{s}' was not uploaded", .{ f.filename, m.package.name });
                return resp.fail(ctx.arena, .upload_invalid, &.{.{ "detail", detail }});
            }
        }
    }
    for (g.members, manifests, sources) |*m, sha, src| {
        m.manifest_sha256 = try s.alloc.dupe(u8, sha.?);
        m.source_commit = if (src) |x| try s.alloc.dupe(u8, x) else null;
    }
    g.commit_hash = try s.alloc.dupe(u8, hash);
    g.status = .validating;
    return resp.json(ctx.arena, .accepted, CommitAnswer{
        .group_id = g.id,
        .status = @tagName(g.status),
        .attempt = g.attempt,
        .status_url = answer.status_url,
    });
}

// ---------------------------------------------------------------------------
// yankGroup
// ---------------------------------------------------------------------------

pub fn yankGroup(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const s = ctx.state;
    if (s.read_only) return resp.fail(ctx.arena, .read_only_mode, &.{});
    const t = switch (try caller(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const g = switch (try load(ctx, t, params[0])) {
        .ok => |g| g,
        .fail => |r| return r,
    };
    // The token must be allowed to yank every member, and the caller must own every member now, creator or not.
    for (g.members) |m| {
        if (!tokenCovers(t, m.package.name, &.{ .yank, .publish })) {
            return resp.fail(ctx.arena, .scope_missing, &.{ .{ "scope", "yank" }, .{ "name", m.package.name } });
        }
    }
    for (g.members) |m| {
        if (!m.package.isOwner(t.user)) return resp.fail(ctx.arena, .not_owner, &.{.{ "name", m.package.name }});
    }
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const yanked = util.getBool(obj, "yanked") orelse return resp.invalid(ctx.arena, "'yanked' must be a boolean");
    const reason = util.getStr(obj, "reason");
    if (yanked and reason == null) return resp.invalid(ctx.arena, "yanking needs a 'reason'");
    if (reason) |r| {
        if (r.len > max_reason) return resp.invalid(ctx.arena, "'reason' is at most 280 characters");
    }
    if (g.status != .visible) {
        const detail = try std.fmt.allocPrint(ctx.arena, "it is {s}; a group can be yanked once it is visible", .{@tagName(g.status)});
        return resp.fail(ctx.arena, .group_not_settled, &.{ .{ "group_id", g.id }, .{ "detail", detail } });
    }
    const current: ?st.YankState = if (g.yank) |y| y.state else null;
    if (yanked) {
        if (current == .unyanking) return notSettled(ctx, g, "it is being unyanked");
        if (current == .yanked) return jsonOmitting(ctx.arena, .ok, try view(ctx.arena, g, false));
        if (current == .yanking) return jsonOmitting(ctx.arena, .accepted, try view(ctx.arena, g, false));
        // A new yank starts from none yanked: what an earlier one changed is no longer the group's to restore.
        for (g.members) |*m| m.yanked_by_group = false;
        g.yank = .{ .state = .yanking, .reason = try s.alloc.dupe(u8, reason.?), .requested_at = s.now() };
        return jsonOmitting(ctx.arena, .accepted, try view(ctx.arena, g, false));
    }
    if (current == null or current == .restored) return jsonOmitting(ctx.arena, .ok, try view(ctx.arena, g, false));
    if (current == .yanking) return notSettled(ctx, g, "it is being yanked");
    if (current == .unyanking) return jsonOmitting(ctx.arena, .accepted, try view(ctx.arena, g, false));
    g.yank.?.state = .unyanking;
    return jsonOmitting(ctx.arena, .accepted, try view(ctx.arena, g, false));
}

fn notSettled(ctx: *Ctx, g: *const st.Group, detail: []const u8) Allocator.Error!Response {
    return resp.fail(ctx.arena, .group_not_settled, &.{ .{ "group_id", g.id }, .{ "detail", detail } });
}
