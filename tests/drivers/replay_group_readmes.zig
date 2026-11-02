//! The recipes of the replay for readmes sent as objects: a create that declares the readme of members, one of them already in
//! storage, and the commits that name a readme by sha256 and size. Used by replay_group_facts.zig.

const std = @import("std");
const c = @import("contract.zig");
const rr = @import("replay_recipes.zig");
const gc = @import("replay_group_conflicts.zig");
const tbl = @import("replay_table.zig");

const README_A = "# first member\n\nAn HTTP/1.1 client.\n";
const README_B = "# second member\n\nA JSON reader.\n";

pub fn build(f: *rr.F, e: tbl.Entry) !tbl.Step {
    const g = try rr.Grp.init(f, 2);
    const both = !std.mem.eql(u8, e.arg, "readme_create_one");
    const create_body = try createBody(g, both);
    if (std.mem.startsWith(u8, e.arg, "readme_create")) {
        // The group is created, the second readme is PUT and the group aborted; the case is the create of the same set again,
        // whose readme upload ids are the same, so the second answers uploaded.
        const first = try create(g, create_body, if (both) 0b10 else 0);
        const gone = try g.f.req("DELETE", try g.f.fmt("/api/v1/groups/{s}", .{first}), null, g.token);
        if (gone.status != 200) return error.AbortFailed;
        var s = rr.step("createGroup");
        s.body = create_body;
        s.token = g.token;
        s.auth = "publishToken";
        s.check = .status_is;
        s.args[0] = "open";
        return s;
    }
    const id = try create(g, create_body, 0b11);
    var s = rr.step("commitGroup");
    s.token = g.token;
    s.auth = "publishToken";
    s.path = try g.path(id);
    const first_ref = try refJson(g, 0);
    const second_ref = try refJson(g, 1);
    const mixed = std.mem.eql(u8, e.arg, "readme_commit_mixed");
    s.body = if (mixed)
        try f.fmt("{{\"members\":[{{\"name\":\"{s}\",\"readme\":{s}}},{{\"name\":\"{s}\",\"readme\":{s}}}]}}", .{ g.names[0], try quoted(f, README_A), g.names[1], second_ref })
    else
        try f.fmt("{{\"members\":[{{\"name\":\"{s}\",\"manifest_sha256\":\"{s}\",\"readme\":{s}}},{{\"name\":\"{s}\"}}]}}", .{ g.names[0], try rr.sha256Hex(f.a, "manifest"), first_ref, g.names[1] });
    s.check = .status_is;
    s.args[0] = "validating";
    return s;
}

fn readmeOf(i: usize) []const u8 {
    return if (i == 0) README_A else README_B;
}

fn refJson(g: rr.Grp, i: usize) ![]u8 {
    const text = readmeOf(i);
    return g.f.fmt("{{\"sha256\":\"{s}\",\"size\":{d}}}", .{ try rr.sha256Hex(g.f.a, text), text.len });
}

fn quoted(f: *rr.F, text: []const u8) ![]u8 {
    return std.json.stringifyAlloc(f.a, text, .{});
}

/// The create request: the group's usual body with `readme` added to the first member, and to the second when `both`.
fn createBody(g: rr.Grp, both: bool) ![]u8 {
    var out = std.ArrayList(u8).init(g.f.a);
    try out.appendSlice("{\"members\":[");
    for (g.names, 0..) |n, i| {
        if (i != 0) try out.append(',');
        const bytes = try g.data(i);
        try out.writer().print(
            "{{\"name\":\"{s}\",\"version\":\"0.4.0\",\"files\":[{{\"subdir\":\"linux-64\",\"filename\":\"mojo-{s}-0.4.0-mojo1.0.0_0.conda\",\"sha256\":\"{s}\",\"size\":{d}}}]",
            .{ n, n, try rr.sha256Hex(g.f.a, bytes), bytes.len },
        );
        if (i == 0 or both) try out.writer().print(",\"readme\":{s}", .{try refJson(g, i)});
        try out.append('}');
    }
    try out.appendSlice("]}");
    return out.items;
}

fn createAnswer(g: rr.Grp, body: []const u8) !std.json.Value {
    const rsp = try g.f.req("POST", "/api/v1/groups", body, g.token);
    if (rsp.status != 201 and rsp.status != 200) return error.CreateFailed;
    return rsp.body orelse error.CreateFailed;
}

/// Creates the group, PUTs the files and the readmes of the members whose bit is set in `readmes`.
fn create(g: rr.Grp, body: []const u8, readmes: u2) ![]const u8 {
    const out = try createAnswer(g, body);
    for (c.getArr(out, "members")) |m| {
        const i = try gc.memberIndex(g.names, m);
        for (c.getArr(m, "files")) |file| try g.put(file, try g.data(i));
        if ((readmes >> @intCast(i)) & 1 == 1) {
            if (c.get(m, "readme")) |r| try g.put(r, readmeOf(i));
        }
    }
    return c.getStr(out, "group_id") orelse error.NoGroupId;
}
