//! The operations `/api/v2` adds or changes (spec/api/openapi-v2.yaml): a namespace and the registration of an
//! organization's, its members, the caller with its namespaces, a package with its namespace instead of owners,
//! creating a package with `PUT`, and the CI identity exchange matched to a namespace's publishers. The operations that
//! only take full names where v1 takes names are v1's handlers, which check names by the request's prefix (keys.zig).
//!
//! GitHub is the fake's own: accounts (`/_fake/users`), organizations with their members (`/_fake/org`), renames
//! (`/_fake/rename`). GitHub is asked about an organization once, when its namespace is registered (`pollNamespace`);
//! after that a write checks only the namespace's member table (state.zig `Namespace.right`), so a member removed is
//! refused at once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const Ctx = api.Ctx;
const st = @import("state.zig");
const resp = @import("resp.zig");
const Response = resp.Response;
const util = @import("util.zig");
const auth = @import("auth.zig");
const publish = @import("publish.zig");
const gr = @import("group_readmes.zig");
const keys = @import("keys.zig");
const names = @import("names.zig");
const ns_errors = @import("ns_errors.zig");
const files = @import("files.zig");

/// `NamespaceInfo`.
pub const Info = struct { namespace: []const u8, kind: []const u8, github_id: u64, login: []const u8 };

/// `n` as `NamespaceInfo`: `login` of a user namespace is what its account is called on GitHub now, of an organization
/// namespace the namespace itself.
pub fn info(s: *st.State, n: *const st.Namespace) Info {
    const login = switch (n.kind) {
        .user => if (s.userById(n.github_id)) |u| u.handle else n.name,
        .org => n.name,
    };
    return .{ .namespace = n.name, .kind = @tagName(n.kind), .github_id = n.github_id, .login = login };
}

/// `value` as JSON with null fields left out, not written as null.
fn jsonOmitting(arena: Allocator, status: std.http.Status, value: anytype) Allocator.Error!Response {
    var buf = std.ArrayList(u8).init(arena);
    std.json.stringify(value, .{ .emit_null_optional_fields = false }, buf.writer()) catch return error.OutOfMemory;
    return .{ .status = status, .body = buf.items };
}

const NamespaceFound = union(enum) { ok: *st.Namespace, fail: Response };

/// The namespace a path segment or body field names: `invalid_namespace` outside the grammar, `namespace_not_found`.
fn findNamespace(ctx: *Ctx, name: []const u8) Allocator.Error!NamespaceFound {
    if (!names.isNamespace(name)) return .{ .fail = try ns_errors.fail(ctx.arena, .invalid_namespace, &.{.{ "namespace", name }}) };
    const n = ctx.state.namespaceByName(name) orelse return .{ .fail = try ns_errors.fail(ctx.arena, .namespace_not_found, &.{.{ "namespace", name }}) };
    return .{ .ok = n };
}

// ---------------------------------------------------------------------------
// Namespaces
// ---------------------------------------------------------------------------

/// `GET /namespaces/{namespace}`: public, no token.
pub fn getNamespace(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const n = switch (try findNamespace(ctx, params[0])) {
        .ok => |n| n,
        .fail => |r| return r,
    };
    return resp.json(ctx.arena, .ok, info(ctx.state, n));
}

/// `POST /namespaces {"namespace"}`, a fresh session: starts the registration of an organization namespace (202). It
/// refuses a string outside the grammar, a reserved one, one any namespace holds already, and a caller that holds no user
/// namespace (`user_not_found`: it could not be named as a member), before GitHub is asked; otherwise it opens a device flow bound to the caller, which `pollNamespace` ends.
pub fn createNamespace(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const t = switch (try auth.freshSession(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const name = util.getStr(obj, "namespace") orelse return resp.invalid(ctx.arena, "'namespace' must be a string");
    if (!names.isNamespace(name)) return ns_errors.fail(ctx.arena, .invalid_namespace, &.{.{ "namespace", name }});
    if (names.isReservedNamespace(name)) return ns_errors.fail(ctx.arena, .namespace_reserved, &.{.{ "namespace", name }});
    if (ctx.state.namespaceByName(name) != null) return ns_errors.fail(ctx.arena, .namespace_taken, &.{.{ "namespace", name }});
    if (usernameOf(ctx.state, t.user) == null) {
        const user = try std.ascii.allocLowerString(ctx.arena, t.user.handle);
        return ns_errors.fail(ctx.arena, .user_not_found, &.{.{ "user", user }});
    }
    const login = try auth.openDevice(ctx.state, name, t.user);
    return auth.deviceStarted(ctx, .accepted, login);
}

fn notOrgAdmin(ctx: *Ctx, name: []const u8) Allocator.Error!Response {
    return ns_errors.fail(ctx.arena, .not_org_admin, &.{.{ "namespace", name }});
}

/// `POST /namespaces/poll {"device_code"}`, a token of the account that started the registration: `pending`, `denied` or
/// `expired` as a login's poll answers; once the person approved, `created` with the namespace (200) when the approving
/// account is the caller's and is an active admin of the GitHub organization whose current login is the namespace, which
/// is when the fake's GitHub is asked. The caller becomes its first owner. The device row is gone after any answer but
/// `pending`.
pub fn pollNamespace(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const t = switch (try auth.userToken(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const code = util.getStr(obj, "device_code") orelse return resp.invalid(ctx.arena, "'device_code' must be a string");
    if (code.len < 16) return resp.invalid(ctx.arena, "'device_code' is at least 16 characters");
    const s = ctx.state;
    const login = s.loginByDeviceCode(code) orelse return resp.fail(ctx.arena, .device_code_unknown, &.{});
    const name = login.org_namespace orelse return resp.fail(ctx.arena, .device_code_unknown, &.{});
    if ((login.account orelse return resp.fail(ctx.arena, .device_code_unknown, &.{})) != t.user) {
        return resp.fail(ctx.arena, .device_code_unknown, &.{});
    }
    switch (login.decision) {
        .denied => {
            s.removeLogin(login);
            return resp.json(ctx.arena, .ok, .{ .status = "denied" });
        },
        .pending => {
            if (s.now() >= login.expires_at) {
                s.removeLogin(login);
                return resp.json(ctx.arena, .ok, .{ .status = "expired" });
            }
            return resp.json(ctx.arena, .ok, .{ .status = "pending", .interval = s.poll_secs });
        },
        .approved => {},
    }
    s.removeLogin(login);
    const approver = login.user.?;
    if (approver != t.user) return ns_errors.fail(ctx.arena, .github_account_mismatch, &.{});
    const org = s.orgByLogin(name) orelse return notOrgAdmin(ctx, name);
    const m = org.membership(approver) orelse return notOrgAdmin(ctx, name);
    if (!m.active or m.role != .admin) return notOrgAdmin(ctx, name);
    if (s.namespaceByName(name) != null) return ns_errors.fail(ctx.arena, .namespace_taken, &.{.{ "namespace", name }});
    const now = s.now();
    const n = try s.add(st.Namespace, &s.namespaces, .{
        .name = name,
        .kind = .org,
        .github_id = org.github_id,
        .created_at = now,
        .created_by = approver.github_id,
    });
    try n.members.append(s.alloc, .{ .user = approver, .role = .owner, .added_by = approver.github_id, .added_at = now });
    try files.rewrite(ctx.arena, s);
    return resp.json(ctx.arena, .ok, .{ .status = "created", .namespace = info(s, n) });
}

// ---------------------------------------------------------------------------
// Members
// ---------------------------------------------------------------------------

const OrgFound = union(enum) { ok: *st.Namespace, fail: Response };

/// The organization namespace a members path names: `findNamespace`'s answers, and `invalid_request` for a user namespace.
fn orgNamespace(ctx: *Ctx, name: []const u8) Allocator.Error!OrgFound {
    const n = switch (try findNamespace(ctx, name)) {
        .ok => |n| n,
        .fail => |r| return .{ .fail = r },
    };
    if (n.kind == .user) {
        const detail = try std.fmt.allocPrint(ctx.arena, "'{s}' is a user namespace; it has no members", .{name});
        return .{ .fail = try resp.invalid(ctx.arena, detail) };
    }
    return .{ .ok = n };
}

/// The answer when `u` is not an owner of the organization namespace `n`, or null when it is: `not_namespace_member` for
/// an account with no row, `not_namespace_owner` for a member.
fn ownerRefusal(ctx: *Ctx, n: *const st.Namespace, u: *const st.User) Allocator.Error!?Response {
    const m = n.member(u) orelse return try ns_errors.fail(ctx.arena, .not_namespace_member, &.{.{ "namespace", n.name }});
    if (m.role != .owner) return try ns_errors.fail(ctx.arena, .not_namespace_owner, &.{.{ "namespace", n.name }});
    return null;
}

const UserFound = union(enum) { ok: *st.User, fail: Response };

/// The account whose mopm username (the name of its user namespace) is `name`, or `user_not_found`; an organization's
/// namespace and a string no namespace has are not usernames.
fn mopmUser(ctx: *Ctx, name: []const u8) Allocator.Error!UserFound {
    if (ctx.state.namespaceByName(name)) |n| {
        if (n.kind == .user) {
            if (ctx.state.userById(n.github_id)) |u| return .{ .ok = u };
        }
    }
    return .{ .fail = try ns_errors.fail(ctx.arena, .user_not_found, &.{.{ "user", name }}) };
}

/// The mopm username of `u`: its user namespace equal to its handle in lower case, else the first of its user namespaces.
fn usernameOf(s: *st.State, u: *const st.User) ?[]const u8 {
    var first: ?[]const u8 = null;
    for (s.namespaces.items) |n| {
        if (n.kind != .user or n.github_id != u.github_id) continue;
        if (std.ascii.eqlIgnoreCase(n.name, u.handle)) return n.name;
        if (first == null) first = n.name;
    }
    return first;
}

/// `Member`.
const MemberOut = struct { user: []const u8, handle: []const u8, github_id: u64, role: []const u8, added_at: []const u8 };

fn memberOut(ctx: *Ctx, m: st.Member) Allocator.Error!MemberOut {
    return .{
        .user = usernameOf(ctx.state, m.user) orelse m.user.handle,
        .handle = m.user.handle,
        .github_id = m.user.github_id,
        .role = @tagName(m.role),
        .added_at = try util.rfc3339(ctx.arena, m.added_at),
    };
}

fn lessMember(_: void, a: MemberOut, b: MemberOut) bool {
    return std.mem.order(u8, a.user, b.user) == .lt;
}

/// `GET /namespaces/{namespace}/members`: the members of an organization namespace by username, for an owner or a member
/// of it.
pub fn listMembers(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const t = switch (try auth.userToken(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const n = switch (try orgNamespace(ctx, params[0])) {
        .ok => |n| n,
        .fail => |r| return r,
    };
    if (n.member(t.user) == null) return ns_errors.fail(ctx.arena, .not_namespace_member, &.{.{ "namespace", n.name }});
    var out = std.ArrayList(MemberOut).init(ctx.arena);
    for (n.members.items) |m| try out.append(try memberOut(ctx, m));
    std.mem.sort(MemberOut, out.items, {}, lessMember);
    return resp.json(ctx.arena, .ok, .{ .namespace = n.name, .members = out.items });
}

/// `PUT /namespaces/{namespace}/members/{user} {"role"}`, a fresh session of an owner: adds the account (201) or sets its
/// role (200, also when it already is that). Making the only owner a member is `last_owner`.
pub fn setMember(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const t = switch (try auth.freshSession(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const n = switch (try orgNamespace(ctx, params[0])) {
        .ok => |n| n,
        .fail => |r| return r,
    };
    if (try ownerRefusal(ctx, n, t.user)) |r| return r;
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const word = util.getStr(obj, "role") orelse return resp.invalid(ctx.arena, "'role' must be a string");
    const role = std.meta.stringToEnum(st.MemberRole, word) orelse return resp.invalid(ctx.arena, "'role' is owner or member");
    const user = switch (try mopmUser(ctx, params[1])) {
        .ok => |u| u,
        .fail => |r| return r,
    };
    const now = ctx.state.now();
    if (n.member(user)) |m| {
        if (m.role != role) {
            if (m.role == .owner and n.ownerCount() == 1) {
                return ns_errors.fail(ctx.arena, .last_owner, &.{ .{ "user", params[1] }, .{ "namespace", n.name } });
            }
            m.role = role;
            m.added_by = t.user.github_id;
            m.added_at = now;
        }
        return resp.json(ctx.arena, .ok, try memberOut(ctx, m.*));
    }
    try n.members.append(ctx.state.alloc, .{ .user = user, .role = role, .added_by = t.user.github_id, .added_at = now });
    return resp.json(ctx.arena, .created, try memberOut(ctx, n.member(user).?.*));
}

/// `DELETE /namespaces/{namespace}/members/{user}`, a fresh session of an owner (204): the account's next write is
/// refused. An owner may remove themselves while another owner remains; the last owner is `last_owner`.
pub fn removeMember(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const t = switch (try auth.freshSession(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const n = switch (try orgNamespace(ctx, params[0])) {
        .ok => |n| n,
        .fail => |r| return r,
    };
    if (try ownerRefusal(ctx, n, t.user)) |r| return r;
    const user = switch (try mopmUser(ctx, params[1])) {
        .ok => |u| u,
        .fail => |r| return r,
    };
    for (n.members.items, 0..) |m, i| {
        if (m.user != user) continue;
        if (m.role == .owner and n.ownerCount() == 1) {
            return ns_errors.fail(ctx.arena, .last_owner, &.{ .{ "user", params[1] }, .{ "namespace", n.name } });
        }
        _ = n.members.orderedRemove(i);
        return resp.empty(.no_content);
    }
    return ns_errors.fail(ctx.arena, .member_not_found, &.{ .{ "user", params[1] }, .{ "namespace", n.name } });
}

// ---------------------------------------------------------------------------
// The caller
// ---------------------------------------------------------------------------

const MeNamespace = struct { namespace: []const u8, kind: []const u8, role: []const u8, packages: []const []const u8 };

fn userFirst(_: void, a: MeNamespace, b: MeNamespace) bool {
    const au = std.mem.eql(u8, a.kind, "user");
    const bu = std.mem.eql(u8, b.kind, "user");
    if (au != bu) return au;
    return std.mem.order(u8, a.namespace, b.namespace) == .lt;
}

/// `GET /me` (`MeV2`): the namespaces the caller can write now, its user namespaces first, each with its packages;
/// `unavailable_namespace` when the caller's login cannot be its namespace.
pub fn getMe(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const t = switch (try auth.userToken(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const s = ctx.state;
    var out = std.ArrayList(MeNamespace).init(ctx.arena);
    for (s.namespaces.items) |n| {
        if (n.right(t.user) != .write) continue;
        var in = std.ArrayList([]const u8).init(ctx.arena);
        for (s.packages.items) |p| {
            const of = p.namespace orelse continue;
            if (of == n) try in.append(p.name);
        }
        std.mem.sort([]const u8, in.items, {}, st.lessString);
        try out.append(.{ .namespace = n.name, .kind = @tagName(n.kind), .role = n.role(t.user), .packages = in.items });
    }
    std.mem.sort(MeNamespace, out.items, {}, userFirst);
    return jsonOmitting(ctx.arena, .ok, .{
        .github_id = t.user.github_id,
        .handle = t.user.handle,
        .namespaces = out.items,
        .unavailable_namespace = s.unavailableNamespace(t.user),
    });
}

// ---------------------------------------------------------------------------
// Packages
// ---------------------------------------------------------------------------

fn packageBody(ctx: *Ctx, p: *st.Package) Allocator.Error!Response {
    const newest = if (publish.latest(p)) |v| publish.findVersion(p, v) else null;
    return gr.withReadme(ctx.arena, try resp.json(ctx.arena, .ok, .{
        .name = p.name,
        .state = @tagName(p.state),
        .namespace = info(ctx.state, p.namespace.?),
        .latest = publish.latest(p),
        .repository = p.repository,
        .license = p.license,
        .description = p.description,
        .created_at = try util.rfc3339(ctx.arena, p.created_at),
        .versions = try publish.summaries(ctx.arena, p),
    }), if (newest) |v| v.readme else null);
}

/// `GET /packages/{namespace}/{name}`: v1's `PackageInfo` with `namespace` (`NamespaceInfo`) instead of `owners`.
pub fn getPackage(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const p = switch (try keys.find(ctx, params[0])) {
        .ok => |p| p,
        .fail => |r| return r,
    };
    return packageBody(ctx, p);
}

/// Whether token `t` names the package `key` for creating it: an API token with `publish` whose `packages` lists it, a
/// CI identity token minted for it (either purpose: a set is staged only once its packages exist). A session always does.
fn tokenNames(t: *const st.Token, key: []const u8) bool {
    switch (t.kind) {
        .session => return true,
        .api => {
            if (std.mem.indexOfScalar(st.Scope, t.scopes, .publish) == null) return false;
            for (t.packages) |p| {
                if (std.mem.eql(u8, p, key)) return true;
            }
            return false;
        },
        .oidc => {
            if (std.mem.eql(u8, t.oidc_package, key)) return true;
            for (t.oidc_set) |nv| {
                if (std.mem.eql(u8, nv.name, key)) return true;
            }
            return false;
        },
    }
}

/// `PUT /packages/{namespace}/{name}`, no body: creates the package in a namespace the caller can write now (201), or
/// answers the package that exists (200). An import name the registry refuses is `name_reserved`; the right to write the
/// namespace is checked before the answer, whether or not the package exists.
pub fn createPackage(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const t = switch (try auth.authenticate(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const key = params[0];
    if (try keys.problem(ctx, key)) |r| return r;
    const s = ctx.state;
    const f = names.split(key).?;
    if (names.isForbiddenImport(f.name)) return resp.fail(ctx.arena, .name_reserved, &.{.{ "name", key }});
    const n = s.namespaceByName(f.namespace) orelse return ns_errors.fail(ctx.arena, .namespace_not_found, &.{.{ "namespace", f.namespace }});
    if (!tokenNames(t, key)) return resp.fail(ctx.arena, .scope_missing, &.{ .{ "scope", "publish" }, .{ "name", key } });
    if (try keys.namespaceRefusal(ctx, n, t.user)) |r| return r;
    if (s.packageByName(key)) |p| return packageBody(ctx, p);
    const now = s.now();
    const p = try s.addPackage(.{
        .name = try s.alloc.dupe(u8, key),
        .namespace = n,
        .created_at = now,
        .updated_at = now,
        .claim_expires_at = 0,
    });
    var r = try packageBody(ctx, p);
    r.status = .created;
    return r;
}

// ---------------------------------------------------------------------------
// CI identity exchange
// ---------------------------------------------------------------------------

/// Whether `repository` is a publisher of the namespace of `key` (a full name whose namespace exists).
fn publishes(s: *st.State, key: []const u8, repository: []const u8) bool {
    const n = s.namespaceByName(names.namespaceOf(key).?) orelse return false;
    for (n.publishers.items) |r| {
        if (std.mem.eql(u8, r, repository)) return true;
    }
    return false;
}

/// `POST /auth/oidc/exchange` under v2: `name` (or each `packages[].name`) is a full name, matched to the publishers of its
/// namespace; it mints a token for the CI identity of the repository and creates nothing (`PUT` creates). A name whose
/// namespace does not have the repository as a publisher, or does not exist, is `oidc_not_trusted` naming it.
pub fn exchangeOidcToken(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const jwt = util.getStr(obj, "jwt") orelse return resp.invalid(ctx.arena, "'jwt' must be a string");
    const stage = if (obj.get("purpose")) |v| switch (v) {
        .string => |w| if (std.mem.eql(u8, w, "stage")) true else if (std.mem.eql(u8, w, "publish")) false else return resp.invalid(ctx.arena, "'purpose' is publish or stage"),
        else => return resp.invalid(ctx.arena, "'purpose' is publish or stage"),
    } else false;

    var wanted = std.ArrayList(st.NameVersion).init(ctx.arena);
    const set_form = obj.get("packages") != null;
    if (set_form) {
        if (obj.get("name") != null or obj.get("version") != null) return resp.invalid(ctx.arena, "send 'packages' or 'name' and 'version', not both");
        const list = switch (obj.get("packages").?) {
            .array => |arr| arr.items,
            else => return resp.invalid(ctx.arena, "'packages' must be an array"),
        };
        if (list.len < 1 or list.len > 500) return resp.invalid(ctx.arena, "'packages' holds 1 to 500 entries");
        for (list) |e| {
            const o = switch (e) {
                .object => |o| o,
                else => return resp.invalid(ctx.arena, "'packages' holds objects"),
            };
            try wanted.append(.{
                .name = util.getStr(o, "name") orelse return resp.invalid(ctx.arena, "'name' must be a string"),
                .version = util.getStr(o, "version") orelse return resp.invalid(ctx.arena, "'version' must be a string"),
            });
        }
    } else {
        try wanted.append(.{
            .name = util.getStr(obj, "name") orelse return resp.invalid(ctx.arena, "'name' must be a string"),
            .version = util.getStr(obj, "version") orelse return resp.invalid(ctx.arena, "'version' must be a string"),
        });
    }
    for (wanted.items, 0..) |w, i| {
        if (try keys.problem(ctx, w.name)) |r| return r;
        if (!util.isVersion(w.version)) return resp.fail(ctx.arena, .invalid_version, &.{.{ "version", w.version }});
        for (wanted.items[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, w.name)) return resp.invalid(ctx.arena, "'packages' names a package twice");
        }
    }
    const repository = auth.oidcRepository(ctx, jwt) orelse
        return resp.fail(ctx.arena, .oidc_token_invalid, &.{.{ "detail", "not a token with a repository claim" }});
    const s = ctx.state;
    for (wanted.items) |w| {
        if (!publishes(s, w.name, repository)) return resp.fail(ctx.arena, .oidc_not_trusted, &.{.{ "name", w.name }});
    }
    var kept = try s.alloc.alloc(st.NameVersion, wanted.items.len);
    for (wanted.items, 0..) |w, i| kept[i] = .{ .name = try s.alloc.dupe(u8, w.name), .version = try s.alloc.dupe(u8, w.version) };
    const now = s.now();
    const t = try s.addToken(.{
        .id = try util.newId(s.alloc, "oidc"),
        .secret = try util.newToken(s.alloc),
        .kind = .oidc,
        .user = try s.ciUser(repository),
        .oidc_package = if (set_form) "" else kept[0].name,
        .oidc_version = if (set_form) "" else kept[0].version,
        .oidc_repository = try s.alloc.dupe(u8, repository),
        .oidc_set = if (set_form) kept else &.{},
        .oidc_stage = stage,
        .created_at = now,
        .expires_at = now + st.oidc_secs,
    });
    const expires_at = try util.rfc3339(ctx.arena, t.expires_at);
    if (set_form) return resp.json(ctx.arena, .ok, .{ .token = t.secret, .token_kind = auth.kindOf(stage), .expires_at = expires_at, .packages = kept });
    return resp.json(ctx.arena, .ok, .{ .token = t.secret, .token_kind = auth.kindOf(stage), .expires_at = expires_at, .name = kept[0].name, .version = kept[0].version });
}
