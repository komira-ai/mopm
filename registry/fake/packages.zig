//! Packages, owners and invitations: search, package info, claims, the
//! version list (filled by publishes), owner changes and invitations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const Ctx = api.Ctx;
const st = @import("state.zig");
const resp = @import("resp.zig");
const Response = resp.Response;
const util = @import("util.zig");
const auth = @import("auth.zig");

/// Names nobody may claim.
const reserved = [_][]const u8{ "mopm", "mojo", "max", "modular", "std", "stdlib" };

const Owner = struct { github_id: u64, handle: []const u8 };

fn owners(arena: Allocator, p: *const st.Package) Allocator.Error![]const Owner {
    var out = std.ArrayList(Owner).init(arena);
    for (p.owners.items) |u| try out.append(.{ .github_id = u.github_id, .handle = u.handle });
    return try out.toOwnedSlice();
}

/// The package named by a path segment, or the error to answer: a name that
/// is not normalised is `invalid_name`, an unknown one `package_not_found`.
const Found = union(enum) { ok: *st.Package, fail: Response };

fn findPackage(ctx: *Ctx, name: []const u8) Allocator.Error!Found {
    if (!util.isName(name)) return .{ .fail = try resp.fail(ctx.arena, .invalid_name, &.{.{ "name", name }}) };
    const p = ctx.state.packageByName(name) orelse return .{ .fail = try resp.fail(ctx.arena, .package_not_found, &.{.{ "name", name }}) };
    return .{ .ok = p };
}

// ---------------------------------------------------------------------------
// Pagination: the cursor is `p` and the offset of the next page.
// ---------------------------------------------------------------------------

const Page = struct { offset: usize, limit: usize };
const PageOr = union(enum) { ok: Page, fail: Response };

fn page(ctx: *Ctx) Allocator.Error!PageOr {
    var out = Page{ .offset = 0, .limit = 20 };
    if (api.queryParam(ctx, "limit")) |v| {
        const n = std.fmt.parseInt(usize, v, 10) catch 0;
        if (n < 1 or n > 100) return .{ .fail = try resp.invalid(ctx.arena, "'limit' must be 1 to 100") };
        out.limit = n;
    }
    if (api.queryParam(ctx, "cursor")) |c| {
        const bad = PageOr{ .fail = try resp.invalid(ctx.arena, "'cursor' is not a cursor this registry gave") };
        if (c.len < 2 or c[0] != 'p') return bad;
        out.offset = std.fmt.parseInt(usize, c[1..], 10) catch return bad;
    }
    return .{ .ok = out };
}

fn nextCursor(arena: Allocator, pg: Page, total: usize) Allocator.Error!?[]const u8 {
    if (pg.offset + pg.limit >= total) return null;
    return try std.fmt.allocPrint(arena, "p{d}", .{pg.offset + pg.limit});
}

fn window(pg: Page, total: usize) struct { usize, usize } {
    const from = @min(pg.offset, total);
    return .{ from, @min(from + pg.limit, total) };
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

fn byName(_: void, a: *st.Package, b: *st.Package) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn byUpdated(_: void, a: *st.Package, b: *st.Package) bool {
    if (a.updated_at != b.updated_at) return a.updated_at > b.updated_at;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

pub fn searchPackages(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const pg = switch (try page(ctx)) {
        .ok => |p| p,
        .fail => |r| return r,
    };
    const q = try util.normalise(ctx.arena, api.queryParam(ctx, "q") orelse "");
    if (q.len > 64) return resp.invalid(ctx.arena, "'q' is at most 64 characters");
    const sort = api.queryParam(ctx, "sort") orelse "name";
    var hits = std.ArrayList(*st.Package).init(ctx.arena);
    for (ctx.state.packages.items) |p| {
        if (std.mem.startsWith(u8, p.name, q)) try hits.append(p);
    }
    if (std.mem.eql(u8, sort, "name")) {
        std.mem.sort(*st.Package, hits.items, {}, byName);
    } else if (std.mem.eql(u8, sort, "updated")) {
        std.mem.sort(*st.Package, hits.items, {}, byUpdated);
    } else return resp.invalid(ctx.arena, "'sort' is name or updated");

    const Summary = struct { name: []const u8, latest: ?[]const u8, description: ?[]const u8, updated_at: []const u8 };
    var out = std.ArrayList(Summary).init(ctx.arena);
    const from, const to = window(pg, hits.items.len);
    for (hits.items[from..to]) |p| {
        try out.append(.{
            .name = p.name,
            .latest = null,
            .description = p.description,
            .updated_at = try util.rfc3339(ctx.arena, p.updated_at),
        });
    }
    return resp.json(ctx.arena, .ok, .{ .packages = out.items, .next_cursor = try nextCursor(ctx.arena, pg, hits.items.len) });
}

pub fn getPackage(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const p = switch (try findPackage(ctx, params[0])) {
        .ok => |p| p,
        .fail => |r| return r,
    };
    const Summary = struct { version: []const u8, state: []const u8, published_at: []const u8 };
    const versions: []const Summary = &.{};
    return resp.json(ctx.arena, .ok, .{
        .name = p.name,
        .state = @tagName(p.state),
        .owners = try owners(ctx.arena, p),
        .latest = @as(?[]const u8, null),
        .repository = p.repository,
        .license = p.license,
        .description = p.description,
        .created_at = try util.rfc3339(ctx.arena, p.created_at),
        .versions = versions,
    });
}

pub fn listVersions(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    _ = switch (try findPackage(ctx, params[0])) {
        .ok => |p| p,
        .fail => |r| return r,
    };
    const pg = switch (try page(ctx)) {
        .ok => |p| p,
        .fail => |r| return r,
    };
    const Summary = struct { version: []const u8, state: []const u8, published_at: []const u8 };
    const versions: []const Summary = &.{};
    return resp.json(ctx.arena, .ok, .{ .versions = versions, .next_cursor = try nextCursor(ctx.arena, pg, 0) });
}

pub fn listOwners(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const p = switch (try findPackage(ctx, params[0])) {
        .ok => |p| p,
        .fail => |r| return r,
    };
    return resp.json(ctx.arena, .ok, .{ .owners = try owners(ctx.arena, p) });
}

// ---------------------------------------------------------------------------
// Claims
// ---------------------------------------------------------------------------

/// `name` without underscores.
fn squash(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.mem.replaceOwned(u8, arena, name, "_", "");
}

/// The existing package `name` is too similar to: equal once underscores are
/// dropped, or the same but for a trailing `s`.
fn similar(ctx: *Ctx, name: []const u8) Allocator.Error!?*st.Package {
    const a = try squash(ctx.arena, name);
    for (ctx.state.packages.items) |p| {
        const b = try squash(ctx.arena, p.name);
        if (std.mem.eql(u8, a, b)) return p;
        if (a.len == b.len + 1 and a[a.len - 1] == 's' and std.mem.startsWith(u8, a, b)) return p;
        if (b.len == a.len + 1 and b[b.len - 1] == 's' and std.mem.startsWith(u8, b, a)) return p;
    }
    return null;
}

pub fn claimPackage(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const t = switch (try auth.userToken(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const name = params[0];
    if (!util.isName(name)) return resp.fail(ctx.arena, .invalid_name, &.{.{ "name", name }});
    var confirm = false;
    if (ctx.body.len > 0) {
        const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
        if (obj.get("confirm_similar")) |v| {
            confirm = switch (v) {
                .bool => |b| b,
                else => return resp.invalid(ctx.arena, "'confirm_similar' must be a boolean"),
            };
        }
    }
    for (reserved) |r| {
        if (std.mem.eql(u8, r, name)) return resp.fail(ctx.arena, .name_reserved, &.{.{ "name", name }});
    }
    if (ctx.state.packageByName(name) != null) return resp.fail(ctx.arena, .name_taken, &.{.{ "name", name }});
    if (!confirm) {
        if (try similar(ctx, name)) |other| {
            return resp.fail(ctx.arena, .name_too_similar, &.{ .{ "name", name }, .{ "other", other.name } });
        }
    }
    const s = ctx.state;
    const now = s.now();
    const p = try s.addPackage(.{
        .name = try s.alloc.dupe(u8, name),
        .created_at = now,
        .updated_at = now,
        .claim_expires_at = now + st.claim_secs,
    });
    try p.owners.append(s.alloc, t.user);
    return resp.json(ctx.arena, .created, .{
        .name = p.name,
        .state = "claimed",
        .claim_expires_at = try util.rfc3339(ctx.arena, p.claim_expires_at),
    });
}

// ---------------------------------------------------------------------------
// Owners and invitations
// ---------------------------------------------------------------------------

fn invitationJson(arena: Allocator, i: *const st.Invitation) Allocator.Error!InvitationJson {
    return .{
        .id = i.id,
        .name = i.package.name,
        .github_id = i.invitee.github_id,
        .handle = i.invitee.handle,
        .inviter = i.inviter.handle,
        .expires_at = try util.rfc3339(arena, i.expires_at),
    };
}

const InvitationJson = struct {
    id: []const u8,
    name: []const u8,
    github_id: u64,
    handle: []const u8,
    inviter: []const u8,
    expires_at: []const u8,
};

/// The package and the caller (a fresh session of one of its owners), or
/// the error to answer.
const OwnerCall = union(enum) { ok: struct { *st.Package, *st.Token }, fail: Response };

fn ownerCall(ctx: *Ctx, name: []const u8) anyerror!OwnerCall {
    const t = switch (try auth.freshSession(ctx)) {
        .ok => |t| t,
        .fail => |r| return .{ .fail = r },
    };
    const p = switch (try findPackage(ctx, name)) {
        .ok => |p| p,
        .fail => |r| return .{ .fail = r },
    };
    if (!p.isOwner(t.user)) return .{ .fail = try resp.fail(ctx.arena, .not_owner, &.{.{ "name", p.name }}) };
    return .{ .ok = .{ p, t } };
}

pub fn inviteOwner(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const p, const t = switch (try ownerCall(ctx, params[0])) {
        .ok => |pt| pt,
        .fail => |r| return r,
    };
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const handle = util.getStr(obj, "handle") orelse return resp.invalid(ctx.arena, "'handle' must be a string");
    if (handle.len == 0) return resp.invalid(ctx.arena, "'handle' must not be empty");
    const s = ctx.state;
    const invitee = s.userByHandle(handle) orelse return resp.fail(ctx.arena, .user_not_found, &.{.{ "handle", handle }});
    if (p.isOwner(invitee)) return resp.fail(ctx.arena, .already_owner, &.{ .{ "handle", invitee.handle }, .{ "name", p.name } });
    const now = s.now();
    for (s.invitations.items) |i| {
        if (i.package == p and i.invitee == invitee and !i.accepted and now < i.expires_at) {
            return resp.json(ctx.arena, .accepted, try invitationJson(ctx.arena, i));
        }
    }
    const i = try s.addInvitation(.{
        .id = try util.newId(s.alloc, "inv"),
        .package = p,
        .invitee = invitee,
        .inviter = t.user,
        .expires_at = now + st.invitation_secs,
    });
    return resp.json(ctx.arena, .accepted, try invitationJson(ctx.arena, i));
}

pub fn removeOwner(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const p, _ = switch (try ownerCall(ctx, params[0])) {
        .ok => |pt| pt,
        .fail => |r| return r,
    };
    const id = std.fmt.parseInt(u64, params[1], 10) catch return resp.invalid(ctx.arena, "'github_id' must be a positive integer");
    for (p.owners.items, 0..) |u, n| {
        if (u.github_id != id) continue;
        if (p.owners.items.len == 1) return resp.fail(ctx.arena, .last_owner, &.{ .{ "handle", u.handle }, .{ "name", p.name } });
        _ = p.owners.orderedRemove(n);
        return resp.empty(.no_content);
    }
    return resp.fail(ctx.arena, .owner_not_found, &.{.{ "name", p.name }});
}

pub fn listInvitations(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const t = switch (try auth.userToken(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    var out = std.ArrayList(InvitationJson).init(ctx.arena);
    for (try ctx.state.pendingInvitations(ctx.arena, t.user)) |i| try out.append(try invitationJson(ctx.arena, i));
    return resp.json(ctx.arena, .ok, .{ .invitations = out.items });
}

pub fn acceptInvitation(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const t = switch (try auth.userToken(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    for (ctx.state.invitations.items) |i| {
        if (i.invitee != t.user or i.accepted or !std.mem.eql(u8, i.id, params[0])) continue;
        if (ctx.state.now() >= i.expires_at) return resp.fail(ctx.arena, .invitation_expired, &.{});
        i.accepted = true;
        if (!i.package.isOwner(t.user)) try i.package.owners.append(ctx.state.alloc, t.user);
        return resp.json(ctx.arena, .ok, .{ .owners = try owners(ctx.arena, i.package) });
    }
    return resp.fail(ctx.arena, .invitation_not_found, &.{});
}
