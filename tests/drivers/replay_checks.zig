//! The assertions of the replay recipes about the live answer, besides the
//! contract checks. Used by replay_test.zig.

const std = @import("std");
const c = @import("contract.zig");
const tbl = @import("replay_table.zig");
const rr = @import("replay_recipes.zig");
const Value = std.json.Value;
const F = rr.F;
const Step = tbl.Step;
const After = tbl.After;

// ------------------------------------------------------------------ checks

fn arrayLen(v: ?Value) ?usize {
    const x = v orelse return null;
    return if (x == .array) x.array.items.len else null;
}

fn ownerHandles(f: *F, body: Value) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(f.a);
    for (c.getArr(body, "owners")) |o| try out.append(c.getStr(o, "handle") orelse "");
    return out.items;
}

fn stateIs(body: Value, want: []const u8) bool {
    return std.mem.eql(u8, c.getStr(body, "state") orelse "", want);
}

fn isNull(v: ?Value) bool {
    return v == null or v.? == .null;
}

/// The recipe's own assertion about the live body.
pub fn runCheck(f: *F, s: Step, body: Value) !bool {
    const a0 = s.args[0];
    switch (s.check) {
        .none => return true,
        .read_only => return if (c.get(body, "read_only")) |v| v == .bool and v.bool else false,
        .tokens_listed => {
            const toks = c.getArr(body, "tokens");
            if (toks.len != 1) return false;
            for (toks) |t| {
                if (c.get(t, "token") != null) return false;
            }
            return true;
        },
        .token_gone => {
            const r = try f.req("GET", "/api/v1/me/tokens", null, a0);
            return r.status == 200 and (arrayLen(c.get(r.body orelse .null, "tokens")) orelse 1) == 0;
        },
        .packages_named => {
            const pk = c.getArr(body, "packages");
            return pk.len == 2 and pk[0] == .string and pk[1] == .string and std.mem.eql(u8, pk[0].string, "http_client") and std.mem.eql(u8, pk[1].string, "http_core");
        },
        .packages_all_current => {
            const pk = c.getStr(body, "packages") orelse return false;
            return std.mem.eql(u8, pk, "all_current");
        },
        .name_is => return std.mem.eql(u8, c.getStr(body, "name") orelse "", a0),
        .first_package_is => {
            const pk = c.getArr(body, "packages");
            return pk.len == 1 and std.mem.eql(u8, c.getStr(pk[0], "name") orelse "", a0);
        },
        .search_prefix => {
            const pk = c.getArr(body, "packages");
            if (pk.len != 2 or !isNull(c.get(body, "next_cursor"))) return false;
            return std.mem.eql(u8, c.getStr(pk[0], "name") orelse "", try f.fmt("{s}a", .{a0})) and
                std.mem.eql(u8, c.getStr(pk[1], "name") orelse "", try f.fmt("{s}b", .{a0}));
        },
        .search_last_page => {
            const pk = c.getArr(body, "packages");
            if (pk.len == 0 or !isNull(c.get(body, "next_cursor"))) return false;
            return std.mem.eql(u8, c.getStr(pk[0], "name") orelse "", try f.fmt("{s}b", .{a0})) and isNull(c.get(pk[0], "latest"));
        },
        .package_info => {
            const handles = try ownerHandles(f, body);
            return handles.len == 1 and std.mem.eql(u8, handles[0], a0) and stateIs(body, "claimed");
        },
        .accepted_owner => {
            for (try ownerHandles(f, body)) |hd| {
                if (std.mem.eql(u8, hd, a0)) return true;
            }
            return false;
        },
        .invitations_names => {
            const inv = c.getArr(body, "invitations");
            return inv.len == 1 and std.mem.eql(u8, c.getStr(inv[0], "name") orelse "", a0);
        },
        .one_owner_left => {
            const r = try f.req("GET", try f.fmt("/api/v1/packages/{s}/owners", .{a0}), null, null);
            return (arrayLen(c.get(r.body orelse .null, "owners")) orelse 0) == 1;
        },
        .status_is => return std.mem.eql(u8, c.getStr(body, "status") orelse "", a0),
        .rejected_with => return std.mem.eql(u8, c.getStr(body, "status") orelse "", "rejected") and std.mem.eql(u8, c.getStr(body, "rejection_code") orelse "", a0),
        .yank_state_yanked => return stateIs(body, "yanked") and std.mem.eql(u8, c.getStr(body, "yank_reason") orelse "", rr.YANK_REASON),
        .unyank_state => return stateIs(body, "published") and isNull(c.get(body, "yank_reason")),
        .state_yanked => return stateIs(body, "yanked"),
        .detail_yanked => {
            const files = c.getArr(body, "files");
            return stateIs(body, "yanked") and std.mem.eql(u8, c.getStr(body, "yank_reason") orelse "", rr.YANK_REASON) and files.len > 0 and c.get(files[0], "url") != null;
        },
        .detail_tombstoned => {
            const files = c.getArr(body, "files");
            const reason = c.getStr(c.get(body, "tombstone") orelse .null, "reason_code") orelse "";
            return stateIs(body, "tombstoned") and files.len > 0 and c.get(files[0], "url") == null and std.mem.eql(u8, reason, "malware");
        },
        .group_failure => {
            const failure = c.get(body, "failure") orelse return false;
            return std.mem.eql(u8, c.getStr(body, "status") orelse "", a0) and std.mem.eql(u8, c.getStr(failure, "code") orelse "", s.args[1]) and
                (c.getStr(failure, "member") orelse "").len > 0;
        },
        .group_yank_state => return std.mem.eql(u8, c.getStr(c.get(body, "yank") orelse .null, "state") orelse "", a0),
        .detail_published => {
            const prov = c.get(body, "provenance") orelse .null;
            return stateIs(body, "published") and std.mem.eql(u8, c.getStr(body, "requires_mojo") orelse "", "==1.0.0") and
                std.mem.eql(u8, c.getStr(prov, "kind") orelse "", "none") and prov.object.count() == 1;
        },
    }
}

/// Undoes a control a recipe set for one case.
pub fn runAfter(f: *F, after: After) !void {
    switch (after) {
        .none => {},
        .read_only_off => _ = try f.control("/mode", "{\"read_only\":false}"),
        .project_limit_restore => _ = try f.control("/limits", "{\"project_bytes\":10000000000}"),
    }
}
