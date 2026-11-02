//! The recipes of the replay that put a fresh fake where a group create
//! answers group_conflict, and the pairing of an answer's members with the
//! names a recipe chose. Used by replay_recipes.zig.

const std = @import("std");
const rr = @import("replay_recipes.zig");
const c = @import("contract.zig");
const tbl = @import("replay_table.zig");
const Value = std.json.Value;

/// The index in `names` of the member an answer entry names. The answer lists
/// the members sorted by name, which is not the order they were named in once
/// a counter reaches two digits.
pub fn memberIndex(names: []const []const u8, entry: Value) !usize {
    const member = c.getStr(entry, "name") orelse return error.NoMemberName;
    for (names, 0..) |n, k| {
        if (std.mem.eql(u8, n, member)) return k;
    }
    return error.UnknownMember;
}

/// The caller may have five groups open: a sixth, sharing nothing with them, has no place.
pub fn openCap(f: *rr.F) !tbl.Step {
    const g = try rr.Grp.init(f, 1);
    for ([_][]const u8{ "0.1.0", "0.2.0", "0.3.0", "0.4.0", "0.5.0" }) |v| _ = try g.create(v, false);
    var s = rr.step("createGroup");
    s.body = try g.body("0.6.0");
    s.token = g.token;
    s.auth = "publishToken";
    return s;
}

/// The caller has a group open; other bytes of the same version are another set that shares it, and the caller refuses overlap.
pub fn overlapRefused(f: *rr.F) !tbl.Step {
    var g = try rr.Grp.init(f, 1);
    _ = try g.create("0.1.0", false);
    g.reject = "other bytes of the same version";
    const again = try g.body("0.1.0");
    var s = rr.step("createGroup");
    s.body = try f.fmt("{s},\"on_overlap\":\"refuse\"}}", .{again[0 .. again.len - 1]});
    s.token = g.token;
    s.auth = "publishToken";
    return s;
}
