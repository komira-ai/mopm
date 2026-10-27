//! The recipes of the replay for what a group read shows (the files of each member), the group a version names, the commits
//! that leave `manifest_sha256` out, and the commits and the version that carry a `source_commit`. `build` answers these and hands every other entry to replay_recipes.zig. Used by
//! replay_test.zig.

const std = @import("std");
const c = @import("contract.zig");
const rr = @import("replay_recipes.zig");
const tbl = @import("replay_table.zig");

const SOURCE_COMMIT = "0123456789abcdef0123456789abcdef01234567";

pub fn build(f: *rr.F, e: tbl.Entry) !tbl.Step {
    if (e.kind != .group_facts) return rr.build(f, e);
    if (std.mem.eql(u8, e.arg, "files_open") or std.mem.eql(u8, e.arg, "files_visible")) {
        const g = try rr.Grp.init(f, 2);
        const open = std.mem.eql(u8, e.arg, "files_open");
        const id = if (open) try g.create("0.4.0", false) else try g.visible("0.4.0");
        var s = try groupStep(g, "getGroup", id);
        s.check = if (open) .group_files_open else .group_files_past_open;
        return s;
    }
    if (std.mem.eql(u8, e.arg, "group_version")) {
        const g = try rr.Grp.init(f, 1);
        const id = try g.visible("0.4.0");
        var s = rr.step("getVersion");
        s.path = try f.json("{{\"name\":\"{s}\",\"version\":\"0.4.0\"}}", .{g.names[0]});
        s.check = .detail_group_id;
        s.args[0] = id;
        return s;
    }
    if (std.mem.eql(u8, e.arg, "commit_single")) {
        const r = try rr.Release.init(f);
        const up = try r.upload("0.4.0", "conda bytes", true, "linux-64", null);
        var s = rr.step("commitPublish");
        s.path = try r.path("0.4.0");
        s.body = try f.fmt("{{\"upload_ids\":[\"{s}\"]}}", .{up});
        s.token = r.token;
        s.auth = "publishToken";
        return s;
    }
    if (std.mem.eql(u8, e.arg, "commit_group")) {
        // The first member gives its manifest hash and the second leaves it out.
        const g = try rr.Grp.init(f, 2);
        const id = try g.create("0.4.0", true);
        var s = try groupStep(g, "commitGroup", id);
        s.body = try f.fmt("{{\"members\":[{{\"name\":\"{s}\",\"manifest_sha256\":\"{s}\"}},{{\"name\":\"{s}\"}}]}}", .{ g.names[0], "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae", g.names[1] });
        s.check = .status_is;
        s.args[0] = "validating";
        return s;
    }
    if (std.mem.eql(u8, e.arg, "source_version")) {
        // A single publish that states its source commit, polled to published; getVersion serves the value.
        const r = try rr.Release.init(f);
        const up = try r.upload("0.4.0", "conda bytes", true, "linux-64", null);
        const rsp = try f.req("POST", try f.fmt("/api/v1/packages/{s}/0.4.0/publish", .{r.name}), try f.fmt("{{\"upload_ids\":[\"{s}\"],\"source_commit\":\"{s}\"}}", .{ up, SOURCE_COMMIT }), r.token);
        if (rsp.status != 202) return error.CommitFailed;
        const out = try r.poll(c.getStr(rsp.body orelse .null, "publish_id") orelse return error.NoPublishId, 4);
        if (!std.mem.eql(u8, c.getStr(out, "status") orelse "", "published")) return error.NotPublished;
        var s = rr.step("getVersion");
        s.path = try r.path("0.4.0");
        s.check = .detail_source_commit;
        s.args[0] = SOURCE_COMMIT;
        return s;
    }
    if (std.mem.eql(u8, e.arg, "commit_single_source")) {
        const r = try rr.Release.init(f);
        const up = try r.upload("0.4.0", "conda bytes", true, "linux-64", null);
        var s = rr.step("commitPublish");
        s.path = try r.path("0.4.0");
        s.body = try f.fmt("{{\"upload_ids\":[\"{s}\"],\"source_commit\":\"{s}\"}}", .{ up, SOURCE_COMMIT });
        s.token = r.token;
        s.auth = "publishToken";
        return s;
    }
    if (std.mem.eql(u8, e.arg, "commit_group_source")) {
        // The first member states its source commit and the second does not.
        const g = try rr.Grp.init(f, 2);
        const id = try g.create("0.4.0", true);
        var s = try groupStep(g, "commitGroup", id);
        s.body = try f.fmt("{{\"members\":[{{\"name\":\"{s}\",\"source_commit\":\"{s}\"}},{{\"name\":\"{s}\"}}]}}", .{ g.names[0], SOURCE_COMMIT, g.names[1] });
        s.check = .status_is;
        s.args[0] = "validating";
        return s;
    }
    return error.UnknownGroupFactsRecipe;
}

fn groupStep(g: rr.Grp, op: []const u8, id: []const u8) !tbl.Step {
    var s = rr.step(op);
    s.token = g.token;
    s.auth = "publishToken";
    s.path = try g.path(id);
    return s;
}
