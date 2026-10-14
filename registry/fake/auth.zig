//! Health, device login, the caller (`/me`) and API tokens, and the bearer
//! checks behind the `userToken` and `freshSession` schemes.

const std = @import("std");
const api = @import("api.zig");
const Ctx = api.Ctx;
const st = @import("state.zig");
const resp = @import("resp.zig");
const Response = resp.Response;
const util = @import("util.zig");

// ---------------------------------------------------------------------------
// Bearer tokens
// ---------------------------------------------------------------------------

pub const Auth = union(enum) { ok: *st.Token, fail: Response };

/// The live token in `Authorization: Bearer ...`, or the error to answer.
pub fn authenticate(ctx: *Ctx) anyerror!Auth {
    const header = ctx.authorization orelse return .{ .fail = try resp.fail(ctx.arena, .token_missing, &.{}) };
    const bearer = "Bearer ";
    if (!std.mem.startsWith(u8, header, bearer)) return .{ .fail = try resp.fail(ctx.arena, .token_unknown, &.{}) };
    const secret = std.mem.trim(u8, header[bearer.len..], " ");
    const t = ctx.state.tokenBySecret(secret) orelse return .{ .fail = try resp.fail(ctx.arena, .token_unknown, &.{}) };
    if (t.revoked) return .{ .fail = try resp.fail(ctx.arena, .token_revoked, &.{}) };
    const now = ctx.state.now();
    if (now >= t.expires_at) {
        return .{ .fail = try resp.fail(ctx.arena, .token_expired, &.{.{ "expires_at", try util.rfc3339(ctx.arena, t.expires_at) }}) };
    }
    t.last_used_at = now;
    return .{ .ok = t };
}

/// `userToken`: a live session or API token (not an OIDC publish token).
pub fn userToken(ctx: *Ctx) anyerror!Auth {
    const a = try authenticate(ctx);
    switch (a) {
        .fail => return a,
        .ok => |t| if (t.kind == .oidc) return .{ .fail = try resp.fail(ctx.arena, .token_unknown, &.{}) },
    }
    return a;
}

/// `freshSession`: a session token younger than 15 minutes.
pub fn freshSession(ctx: *Ctx) anyerror!Auth {
    const a = try authenticate(ctx);
    switch (a) {
        .fail => return a,
        .ok => |t| if (t.kind != .session or ctx.state.now() >= t.fresh_until) {
            return .{ .fail = try resp.fail(ctx.arena, .stale_session, &.{}) };
        },
    }
    return a;
}

// ---------------------------------------------------------------------------
// Health and device login
// ---------------------------------------------------------------------------

pub fn getHealth(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    return resp.json(ctx.arena, .ok, .{
        .status = "ok",
        .stage = ctx.state.stage,
        .api_version = "v1",
        .read_only = ctx.state.read_only,
    });
}

pub fn startDeviceLogin(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const client = util.getStr(obj, "client") orelse return resp.invalid(ctx.arena, "'client' must be a string");
    if (client.len == 0 or client.len > 80) return resp.invalid(ctx.arena, "'client' must be 1 to 80 characters");
    const s = ctx.state;
    var code_bytes: [20]u8 = undefined;
    std.crypto.random.bytes(&code_bytes);
    var user_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&user_bytes);
    var user_code: [9]u8 = undefined;
    for (0..4) |i| {
        user_code[i] = 'A' + user_bytes[i] % 26;
        user_code[5 + i] = '0' + (user_bytes[i] >> 3) % 10;
    }
    user_code[4] = '-';
    const login = try s.addLogin(.{
        .device_code = try std.fmt.allocPrint(s.alloc, "{s}", .{std.fmt.fmtSliceHexLower(&code_bytes)}),
        .user_code = try s.alloc.dupe(u8, &user_code),
        .expires_at = s.now() + st.device_secs,
    });
    return resp.json(ctx.arena, .ok, .{
        .device_code = login.device_code,
        .user_code = login.user_code,
        .verification_uri = try std.fmt.allocPrint(ctx.arena, "{s}/device", .{s.base_url}),
        .expires_in = st.device_secs,
        .interval = st.poll_interval,
    });
}

pub fn pollDeviceLogin(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const code = util.getStr(obj, "device_code") orelse return resp.invalid(ctx.arena, "'device_code' must be a string");
    if (code.len < 16) return resp.invalid(ctx.arena, "'device_code' is at least 16 characters");
    const s = ctx.state;
    const login = s.loginByDeviceCode(code) orelse return resp.fail(ctx.arena, .device_code_unknown, &.{});
    switch (login.decision) {
        .denied => return resp.json(ctx.arena, .ok, .{ .status = "denied" }),
        .pending => {
            if (s.now() >= login.expires_at) return resp.json(ctx.arena, .ok, .{ .status = "expired" });
            return resp.json(ctx.arena, .ok, .{ .status = "pending", .interval = st.poll_interval });
        },
        .approved => {
            const t = login.token orelse blk: {
                const fresh = try s.newSession(login.user.?, true);
                login.token = fresh;
                break :blk fresh;
            };
            return resp.json(ctx.arena, .ok, .{
                .status = "approved",
                .token = t.secret,
                .token_kind = "session",
                .expires_at = try util.rfc3339(ctx.arena, t.expires_at),
                .fresh_until = try util.rfc3339(ctx.arena, t.fresh_until),
                .handle = t.user.handle,
            });
        },
    }
}

// ---------------------------------------------------------------------------
// The caller and API tokens
// ---------------------------------------------------------------------------

pub fn getMe(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const t = switch (try userToken(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    return resp.json(ctx.arena, .ok, .{
        .github_id = t.user.github_id,
        .handle = t.user.handle,
        .packages = try ctx.state.ownedNames(ctx.arena, t.user),
        .pending_invitations = (try ctx.state.pendingInvitations(ctx.arena, t.user)).len,
    });
}

/// `packages` of a token as the API writes it: a list, or `"all_current"`.
const Packages = struct {
    t: *const st.Token,
    pub fn jsonStringify(self: Packages, jw: anytype) !void {
        if (self.t.all_current) try jw.write("all_current") else try jw.write(self.t.packages);
    }
};

pub fn createToken(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const session = switch (try freshSession(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const s = ctx.state;
    const name = util.getStr(obj, "name") orelse return resp.invalid(ctx.arena, "'name' must be a string");
    if (name.len == 0 or name.len > 80) return resp.invalid(ctx.arena, "'name' must be 1 to 80 characters");
    const days = util.getInt(obj, "expires_in_days") orelse return resp.invalid(ctx.arena, "'expires_in_days' must be an integer");
    if (days < 1 or days > 90) return resp.invalid(ctx.arena, "'expires_in_days' must be 1 to 90");

    var scopes = std.ArrayList(st.Scope).init(s.alloc);
    const scope_values = switch (obj.get("scopes") orelse return resp.invalid(ctx.arena, "'scopes' is required")) {
        .array => |a| a.items,
        else => return resp.invalid(ctx.arena, "'scopes' must be an array"),
    };
    if (scope_values.len == 0) return resp.invalid(ctx.arena, "'scopes' must not be empty");
    for (scope_values) |v| {
        const word = switch (v) {
            .string => |w| w,
            else => return resp.invalid(ctx.arena, "each scope must be a string"),
        };
        const scope = std.meta.stringToEnum(st.Scope, word) orelse return resp.invalid(ctx.arena, "a scope is publish or yank");
        if (std.mem.indexOfScalar(st.Scope, scopes.items, scope) != null) return resp.invalid(ctx.arena, "'scopes' repeats a scope");
        try scopes.append(scope);
    }

    var all_current = false;
    var packages = std.ArrayList([]const u8).init(s.alloc);
    switch (obj.get("packages") orelse return resp.invalid(ctx.arena, "'packages' is required")) {
        .string => |w| {
            if (!std.mem.eql(u8, w, "all_current")) return resp.invalid(ctx.arena, "'packages' is a list of names or \"all_current\"");
            all_current = true;
            // A snapshot of the caller's packages now, not future claims.
            for (try s.ownedNames(ctx.arena, session.user)) |owned| try packages.append(try s.alloc.dupe(u8, owned));
        },
        .array => |a| {
            if (a.items.len == 0) return resp.invalid(ctx.arena, "'packages' must not be empty");
            for (a.items) |v| {
                const pkg = switch (v) {
                    .string => |w| w,
                    else => return resp.invalid(ctx.arena, "each package must be a string"),
                };
                if (!util.isName(pkg)) return resp.fail(ctx.arena, .invalid_name, &.{.{ "name", pkg }});
                for (packages.items) |seen| {
                    if (std.mem.eql(u8, seen, pkg)) return resp.invalid(ctx.arena, "'packages' repeats a name");
                }
                try packages.append(try s.alloc.dupe(u8, pkg));
            }
        },
        else => return resp.invalid(ctx.arena, "'packages' is a list of names or \"all_current\""),
    }

    const now = s.now();
    const t = try s.addToken(.{
        .id = try util.newId(s.alloc, "tok"),
        .secret = try util.newToken(s.alloc),
        .kind = .api,
        .user = session.user,
        .name = try s.alloc.dupe(u8, name),
        .scopes = try scopes.toOwnedSlice(),
        .packages = try packages.toOwnedSlice(),
        .all_current = all_current,
        .created_at = now,
        .expires_at = now + days * st.day,
    });
    return resp.json(ctx.arena, .created, .{
        .id = t.id,
        .name = t.name,
        .token = t.secret,
        .scopes = t.scopes,
        .packages = Packages{ .t = t },
        .expires_at = try util.rfc3339(ctx.arena, t.expires_at),
    });
}

pub fn listTokens(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const session = switch (try freshSession(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    const Meta = struct {
        id: []const u8,
        name: []const u8,
        scopes: []const st.Scope,
        packages: Packages,
        created_at: []const u8,
        expires_at: []const u8,
        last_used_at: ?[]const u8,
    };
    var out = std.ArrayList(Meta).init(ctx.arena);
    const now = ctx.state.now();
    for (ctx.state.tokens.items) |t| {
        if (t.kind != .api or t.user != session.user or t.revoked or now >= t.expires_at) continue;
        try out.append(.{
            .id = t.id,
            .name = t.name,
            .scopes = t.scopes,
            .packages = .{ .t = t },
            .created_at = try util.rfc3339(ctx.arena, t.created_at),
            .expires_at = try util.rfc3339(ctx.arena, t.expires_at),
            .last_used_at = if (t.last_used_at) |at| try util.rfc3339(ctx.arena, at) else null,
        });
    }
    return resp.json(ctx.arena, .ok, .{ .tokens = out.items });
}

pub fn revokeToken(ctx: *Ctx, params: []const []const u8) anyerror!Response {
    const session = switch (try freshSession(ctx)) {
        .ok => |t| t,
        .fail => |r| return r,
    };
    for (ctx.state.tokens.items) |t| {
        if (t.kind == .api and t.user == session.user and !t.revoked and std.mem.eql(u8, t.id, params[0])) {
            t.revoked = true;
            return resp.empty(.no_content);
        }
    }
    return resp.fail(ctx.arena, .token_not_found, &.{});
}

// ---------------------------------------------------------------------------
// CI identity exchange (OIDC)
// ---------------------------------------------------------------------------

/// The `repository` claim of a JWT-shaped CI identity token (three base64url
/// parts, the middle one a JSON object), or null. The fake checks the shape
/// and the claim, not a signature: there is no identity provider to ask.
fn oidcRepository(ctx: *Ctx, jwt: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next() orelse return null;
    const payload = parts.next() orelse return null;
    _ = parts.next() orelse return null;
    if (parts.next() != null) return null;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const n = decoder.calcSizeForSlice(payload) catch return null;
    const buf = ctx.arena.alloc(u8, n) catch return null;
    decoder.decode(buf, payload) catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, buf, .{}) catch return null;
    return switch (v) {
        .object => |o| util.getStr(o, "repository"),
        else => null,
    };
}

pub fn exchangeOidcToken(ctx: *Ctx, _: []const []const u8) anyerror!Response {
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const jwt = util.getStr(obj, "jwt") orelse return resp.invalid(ctx.arena, "'jwt' must be a string");
    const name = util.getStr(obj, "name") orelse return resp.invalid(ctx.arena, "'name' must be a string");
    const version = util.getStr(obj, "version") orelse return resp.invalid(ctx.arena, "'version' must be a string");
    if (!util.isName(name)) return resp.fail(ctx.arena, .invalid_name, &.{.{ "name", name }});
    if (!util.isVersion(version)) return resp.fail(ctx.arena, .invalid_version, &.{.{ "version", version }});
    const repository = oidcRepository(ctx, jwt) orelse
        return resp.fail(ctx.arena, .oidc_token_invalid, &.{.{ "detail", "not a token with a repository claim" }});
    const s = ctx.state;
    const p = s.packageByName(name) orelse return resp.fail(ctx.arena, .oidc_not_trusted, &.{.{ "name", name }});
    for (p.trusted.items) |r| {
        if (!std.mem.eql(u8, r, repository)) continue;
        const now = s.now();
        const t = try s.addToken(.{
            .id = try util.newId(s.alloc, "oidc"),
            .secret = try util.newToken(s.alloc),
            .kind = .oidc,
            .user = p.owners.items[0],
            .oidc_package = p.name,
            .oidc_version = try s.alloc.dupe(u8, version),
            .oidc_repository = r,
            .created_at = now,
            .expires_at = now + st.oidc_secs,
        });
        return resp.json(ctx.arena, .ok, .{
            .token = t.secret,
            .token_kind = "publish",
            .expires_at = try util.rfc3339(ctx.arena, t.expires_at),
            .name = p.name,
            .version = t.oidc_version,
        });
    }
    return resp.fail(ctx.arena, .oidc_not_trusted, &.{.{ "name", name }});
}
