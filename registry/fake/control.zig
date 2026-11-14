//! Test controls under `/_fake/`. Not part of the contract and absent from the
//! hosted registry: they put the fake in the states a test needs (a second
//! account, a stale session, time passing, read-only mode, a server fault, a
//! GitHub organization and its members).
//! Every control is a POST with a JSON object body and answers 200 with JSON.

const std = @import("std");
const api = @import("api.zig");
const Ctx = api.Ctx;
const errors = @import("errors.zig");
const resp = @import("resp.zig");
const Response = resp.Response;
const util = @import("util.zig");
const files = @import("files.zig");
const st = @import("state.zig");

pub fn handle(ctx: *Ctx) anyerror!Response {
    if (ctx.method != .POST) return resp.invalid(ctx.arena, "the /_fake controls take POST");
    const obj = ctx.object() orelse return resp.invalid(ctx.arena, "the body is not a JSON object");
    const s = ctx.state;
    const path = ctx.path["/_fake".len..];

    // {"handle"} -> {"github_id", "handle"}: a GitHub account the fake knows.
    if (std.mem.eql(u8, path, "/users")) {
        const who = util.getStr(obj, "handle") orelse return resp.invalid(ctx.arena, "'handle' must be a string");
        const u = try s.ensureUser(who);
        return resp.json(ctx.arena, .ok, .{ .github_id = u.github_id, .handle = u.handle });
    }
    // {"handle", "fresh"?} -> {"token"}: a session token, as a login would
    // give, fresh unless "fresh" is false. Like a login, it makes the user
    // namespace of the handle when that is free.
    if (std.mem.eql(u8, path, "/session")) {
        const who = util.getStr(obj, "handle") orelse return resp.invalid(ctx.arena, "'handle' must be a string");
        const u = try s.ensureUser(who);
        const t = try s.newSession(u, util.getBool(obj, "fresh") orelse true);
        if (try s.loginNamespace(u) != null) try files.rewrite(ctx.arena, s);
        return resp.json(ctx.arena, .ok, .{ .token = t.secret });
    }
    // {"login", "installed"?, "members"?: [{"handle", "role", "state"?}]} -> {"github_id", "login"}: a GitHub
    // organization (made on first use). "installed" installs the mopm registry App (a new installation each time it goes
    // from false to true) or removes it; "members" replaces the members: role admin, member or billing_manager, state
    // active (the default) or pending.
    if (std.mem.eql(u8, path, "/org")) return org(ctx, obj);
    // {"login", "to"}: the GitHub account or organization `login` is called `to` from now on. Namespaces keep their name.
    if (std.mem.eql(u8, path, "/rename")) {
        const login = util.getStr(obj, "login") orelse return resp.invalid(ctx.arena, "'login' must be a string");
        const to = util.getStr(obj, "to") orelse return resp.invalid(ctx.arena, "'to' must be a string");
        if (s.userByHandle(to) != null or s.orgByLogin(to) != null) return resp.invalid(ctx.arena, "another account has that login");
        if (s.userByHandle(login)) |u| {
            u.handle = try s.alloc.dupe(u8, to);
        } else if (s.orgByLogin(login)) |o| {
            o.login = try s.alloc.dupe(u8, to);
        } else return resp.invalid(ctx.arena, "no account or organization has that login");
        try files.rewrite(ctx.arena, s);
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"enabled"}: whether /api/v1 still creates packages (the default). Off, claimPackage and the OIDC `packages` form
    // for a name nobody has answer name_reserved with the hint to update mopm, as the registry does once names are in
    // namespaces.
    if (std.mem.eql(u8, path, "/v1_creation")) {
        s.v1_creation = util.getBool(obj, "enabled") orelse return resp.invalid(ctx.arena, "'enabled' must be a boolean");
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"user_code", "decision": "approve"|"deny", "handle"}: the person's
    // answer on the approval page.
    if (std.mem.eql(u8, path, "/device")) {
        const code = util.getStr(obj, "user_code") orelse return resp.invalid(ctx.arena, "'user_code' must be a string");
        const login = s.loginByUserCode(code) orelse return resp.invalid(ctx.arena, "no device login has that user code");
        const decision = util.getStr(obj, "decision") orelse return resp.invalid(ctx.arena, "'decision' must be a string");
        if (std.mem.eql(u8, decision, "approve")) {
            const who = util.getStr(obj, "handle") orelse return resp.invalid(ctx.arena, "approving needs a 'handle'");
            login.user = try s.ensureUser(who);
            login.decision = .approved;
        } else if (std.mem.eql(u8, decision, "deny")) {
            login.decision = .denied;
        } else return resp.invalid(ctx.arena, "'decision' is approve or deny");
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"advance_seconds"}: move the fake's clock forward.
    if (std.mem.eql(u8, path, "/clock")) {
        const secs = util.getInt(obj, "advance_seconds") orelse return resp.invalid(ctx.arena, "'advance_seconds' must be an integer");
        if (secs < 0) return resp.invalid(ctx.arena, "the clock only moves forward");
        s.clock_offset += secs;
        return resp.json(ctx.arena, .ok, .{ .now = try util.rfc3339(ctx.arena, s.now()) });
    }
    // {"read_only"}: refuse new uploads (read_only_mode), as a stage can.
    if (std.mem.eql(u8, path, "/mode")) {
        s.read_only = util.getBool(obj, "read_only") orelse return resp.invalid(ctx.arena, "'read_only' must be a boolean");
        try files.rewrite(ctx.arena, s);
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"project_bytes"}: the most bytes one package's live files may hold
    // (limit_exceeded at beginUpload beyond it).
    if (std.mem.eql(u8, path, "/limits")) {
        const n = util.getInt(obj, "project_bytes") orelse return resp.invalid(ctx.arena, "'project_bytes' must be an integer");
        if (n < 1) return resp.invalid(ctx.arena, "'project_bytes' must be at least 1");
        s.project_bytes = @intCast(n);
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"operation", "code"}: the next request to that operationId answers that
    // error code (rate_limited, unavailable, internal_error, ...).
    if (std.mem.eql(u8, path, "/fault")) {
        const op = util.getStr(obj, "operation") orelse return resp.invalid(ctx.arena, "'operation' must be a string");
        const word = util.getStr(obj, "code") orelse return resp.invalid(ctx.arena, "'code' must be a string");
        const code = std.meta.stringToEnum(errors.Code, word) orelse return resp.invalid(ctx.arena, "'code' is not in the catalogue");
        try s.faults.append(s.alloc, .{ .operation = try s.alloc.dupe(u8, op), .code = code });
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"enabled"}: whether group publishing is on. Off, createGroup answers
    // route_not_found, as a registry that has not enabled groups does.
    if (std.mem.eql(u8, path, "/groups")) {
        s.groups_enabled = util.getBool(obj, "enabled") orelse return resp.invalid(ctx.arena, "'enabled' must be a boolean");
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"enabled"}: whether the registry takes group readmes as uploaded objects (the default). Off, /health lists no features,
    // createGroup ignores a member's `readme`, and commitGroup refuses a readme that is not a string.
    if (std.mem.eql(u8, path, "/readme_objects")) {
        s.readme_objects = util.getBool(obj, "enabled") orelse return resp.invalid(ctx.arena, "'enabled' must be a boolean");
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"advance_seconds"}: the clock moves forward by that much when the next
    // group commit arrives (once), so a group can pass its deadline between
    // the create and the commit.
    if (std.mem.eql(u8, path, "/commit_clock")) {
        const secs = util.getInt(obj, "advance_seconds") orelse return resp.invalid(ctx.arena, "'advance_seconds' must be an integer");
        if (secs < 0) return resp.invalid(ctx.arena, "the clock only moves forward");
        s.clock_jump_on_commit = secs;
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"after"}: after that many more PUTs of upload bytes, the next one answers
    // unavailable (once), as storage can fail in the middle of a group.
    if (std.mem.eql(u8, path, "/put_fault")) {
        const n = util.getInt(obj, "after") orelse return resp.invalid(ctx.arena, "'after' must be an integer");
        if (n < 0) return resp.invalid(ctx.arena, "'after' must not be negative");
        s.put_fault_after = @intCast(n);
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"name", "repository"}: a trusted publisher of the package, so a CI
    // identity token whose repository claim is that repository may publish.
    // {"namespace", "repository"}: a trusted publisher of a namespace, for
    // /api/v2's exchange: it may create and publish any package there.
    if (std.mem.eql(u8, path, "/trusted")) {
        const repository = util.getStr(obj, "repository") orelse return resp.invalid(ctx.arena, "'repository' must be a string");
        if (util.getStr(obj, "namespace")) |n| {
            const in = s.namespaceByName(n) orelse return resp.invalid(ctx.arena, "no such namespace");
            try in.publishers.append(s.alloc, try s.alloc.dupe(u8, repository));
            return resp.json(ctx.arena, .ok, .{});
        }
        const name = util.getStr(obj, "name") orelse return resp.invalid(ctx.arena, "'name' must be a string");
        const p = s.packageByName(name) orelse return resp.invalid(ctx.arena, "no such package");
        try p.trusted.append(s.alloc, try s.alloc.dupe(u8, repository));
        return resp.json(ctx.arena, .ok, .{});
    }
    // {"repository"}: a CI publisher the deployment trusts by configuration: its identity may use the `packages` form of
    // the exchange, for packages that are unclaimed or already its own.
    if (std.mem.eql(u8, path, "/ci_publisher")) {
        const repository = util.getStr(obj, "repository") orelse return resp.invalid(ctx.arena, "'repository' must be a string");
        try s.ci_repos.append(s.alloc, try s.alloc.dupe(u8, repository));
        return resp.json(ctx.arena, .ok, .{});
    }
    // {} -> {"stage", "publish"}: how many CI-identity tokens the exchange has minted so far, by kind. A test reads it before and
    // after a run to see which kind of token the run asked for (the token itself never leaves the program that holds it).
    if (std.mem.eql(u8, path, "/oidc_tokens")) {
        var staged: usize = 0;
        var published: usize = 0;
        for (s.tokens.items) |t| {
            if (t.kind != .oidc) continue;
            if (t.oidc_stage) staged += 1 else published += 1;
        }
        return resp.json(ctx.arena, .ok, .{ .stage = staged, .publish = published });
    }
    // {} -> {"conda"}: how many `.conda` files `GET /channel/...` has served so far. A test reads it before and after a
    // run to count the package downloads the run made.
    if (std.mem.eql(u8, path, "/served")) {
        return resp.json(ctx.arena, .ok, .{ .conda = s.conda_served });
    }
    // {} -> {"requests"}: how many requests the fake has answered that were not a control, uploads included; a test reads it
    // before and after a run to see whether the run sent anything.
    if (std.mem.eql(u8, path, "/requests")) {
        return resp.json(ctx.arena, .ok, .{ .requests = s.api_requests });
    }
    // {"name", "version", "reason_code"}: an administrator's takedown. The
    // bytes are gone (no url); the number and the sha256 stay.
    if (std.mem.eql(u8, path, "/tombstone")) {
        const name = util.getStr(obj, "name") orelse return resp.invalid(ctx.arena, "'name' must be a string");
        const version = util.getStr(obj, "version") orelse return resp.invalid(ctx.arena, "'version' must be a string");
        const reason = util.getStr(obj, "reason_code") orelse return resp.invalid(ctx.arena, "'reason_code' must be a string");
        const p = s.packageByName(name) orelse return resp.invalid(ctx.arena, "no such package");
        for (p.versions.items) |v| {
            if (!std.mem.eql(u8, v.version, version) or !v.visible()) continue;
            v.state = .tombstoned;
            v.tombstone_reason = try s.alloc.dupe(u8, reason);
            v.tombstone_at = s.now();
            try files.removeFiles(s, v);
            try files.rewrite(ctx.arena, s);
            return resp.json(ctx.arena, .ok, .{});
        }
        return resp.invalid(ctx.arena, "no such published version");
    }
    return resp.invalid(ctx.arena, "no such control");
}

fn org(ctx: *Ctx, obj: std.json.ObjectMap) anyerror!Response {
    const s = ctx.state;
    const login = util.getStr(obj, "login") orelse return resp.invalid(ctx.arena, "'login' must be a string");
    if (login.len == 0) return resp.invalid(ctx.arena, "'login' must not be empty");
    const o = s.orgByLogin(login) orelse blk: {
        if (s.userByHandle(login) != null) return resp.invalid(ctx.arena, "a user account has that login");
        const made = try s.add(st.Org, &s.orgs, .{ .login = try s.alloc.dupe(u8, login), .github_id = s.next_github_id });
        s.next_github_id += 1;
        break :blk made;
    };
    if (obj.get("installed")) |v| {
        const installed = switch (v) {
            .bool => |b| b,
            else => return resp.invalid(ctx.arena, "'installed' must be a boolean"),
        };
        if (!installed) {
            o.installation_id = 0;
        } else if (o.installation_id == 0) {
            o.installation_id = s.next_installation_id;
            s.next_installation_id += 1;
        }
    }
    if (obj.get("members")) |v| {
        const list = switch (v) {
            .array => |a| a.items,
            else => return resp.invalid(ctx.arena, "'members' must be an array"),
        };
        var members = std.ArrayListUnmanaged(st.Membership){};
        for (list) |item| {
            const m = switch (item) {
                .object => |m| m,
                else => return resp.invalid(ctx.arena, "a member is a JSON object"),
            };
            const who = util.getStr(m, "handle") orelse return resp.invalid(ctx.arena, "a member's 'handle' must be a string");
            const role_word = util.getStr(m, "role") orelse return resp.invalid(ctx.arena, "a member's 'role' must be a string");
            const role = std.meta.stringToEnum(st.OrgRole, role_word) orelse return resp.invalid(ctx.arena, "'role' is admin, member or billing_manager");
            const state_word = util.getStr(m, "state") orelse "active";
            const active = if (std.mem.eql(u8, state_word, "active")) true else if (std.mem.eql(u8, state_word, "pending")) false else return resp.invalid(ctx.arena, "'state' is active or pending");
            try members.append(s.alloc, .{ .user = try s.ensureUser(who), .role = role, .active = active });
        }
        o.members = members;
    }
    try files.rewrite(ctx.arena, s);
    return resp.json(ctx.arena, .ok, .{ .github_id = o.github_id, .login = o.login });
}
