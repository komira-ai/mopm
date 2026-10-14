//! Test controls under `/_fake/`. Not part of the contract and absent from the
//! hosted registry: they put the fake in the states a test needs (a second
//! account, a stale session, time passing, read-only mode, a server fault).
//! Every control is a POST with a JSON object body and answers 200 with JSON.

const std = @import("std");
const api = @import("api.zig");
const Ctx = api.Ctx;
const errors = @import("errors.zig");
const resp = @import("resp.zig");
const Response = resp.Response;
const util = @import("util.zig");

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
    // give, fresh unless "fresh" is false.
    if (std.mem.eql(u8, path, "/session")) {
        const who = util.getStr(obj, "handle") orelse return resp.invalid(ctx.arena, "'handle' must be a string");
        const u = try s.ensureUser(who);
        const t = try s.newSession(u, util.getBool(obj, "fresh") orelse true);
        return resp.json(ctx.arena, .ok, .{ .token = t.secret });
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
    return resp.invalid(ctx.arena, "no such control");
}
