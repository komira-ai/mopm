//! Unit tests of `source_commit` on the fake registry (source_commit.zig), on a single publish and on a group commit: what is stored
//! and served, what is refused, and what a repeated commit must say. Each test sends requests through `api.handle` and reads the
//! answers as a client would; the wire shapes are held to the contract by //:contract_replay.

const std = @import("std");
const t = @import("groups_test.zig");
const Fx = t.Fx;
const Reply = t.Reply;
const abc = t.abc;
const idOf = t.idOf;
const expectCode = t.expectCode;

const sha40 = "a" ** 40;
const sha64 = "0123456789abcdef" ** 4;
const other40 = "b" ** 40;
const q40 = "\"" ++ sha40 ++ "\"";
const q64 = "\"" ++ sha64 ++ "\"";
const qother = "\"" ++ other40 ++ "\"";

/// Every form the field refuses, as the JSON text of the value.
const invalid_forms = [_][]const u8{
    "\"" ++ ("A" ** 40) ++ "\"", // uppercase
    "\"" ++ ("a" ** 39) ++ "\"",
    "\"" ++ ("a" ** 41) ++ "\"",
    "\"" ++ ("a" ** 63) ++ "\"",
    "\"" ++ ("a" ** 65) ++ "\"",
    "\"abc1234\"",
    "\"\"",
    "\"" ++ ("a" ** 39) ++ "g\"", // not hex
    "\" " ++ ("a" ** 39) ++ "\"",
    "1234",
    "null",
    "true",
    "{\"sha\":" ++ q40 ++ "}",
    "[" ++ q40 ++ "]",
};

fn begin(fx: *Fx, name: []const u8, version: []const u8, content: []const u8) ![]const u8 {
    const a = fx.life.allocator();
    const r = try fx.call(.POST, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/{s}/files", .{ name, version }), try std.fmt.allocPrint(a,
        \\{{"subdir":"noarch","filename":"mojo-{s}-{s}-mojo1.0.0_0.conda","sha256":"{s}","size":{d}}}
    , .{ name, version, try fx.sha(content), content.len }), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    const id = r.value.object.get("upload_id").?.string;
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try std.fmt.allocPrint(a, "/_fake/upload/{s}", .{id}), content, null)).status);
    return id;
}

/// The commit of one upload; `extra` is more members of the body, with their leading comma, or "".
fn commitSingle(fx: *Fx, name: []const u8, version: []const u8, upload_id: []const u8, extra: []const u8) !Reply {
    const a = fx.life.allocator();
    const body = try std.fmt.allocPrint(a, "{{\"upload_ids\":[\"{s}\"]{s}}}", .{ upload_id, extra });
    return fx.call(.POST, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/{s}/publish", .{ name, version }), body, fx.alice_token);
}

/// A single publish to the end: begin, PUT, commit and the polls that finish it.
fn publishSingle(fx: *Fx, name: []const u8, version: []const u8, extra: []const u8) !Reply {
    const id = try begin(fx, name, version, "bytes");
    const r = try commitSingle(fx, name, version, id, extra);
    if (r.status != 202) return r;
    for (0..3) |_| _ = try fx.call(.GET, r.value.object.get("status_url").?.string, "", fx.alice_token);
    return r;
}

fn versionReply(fx: *Fx, name: []const u8, version: []const u8) !Reply {
    return fx.call(.GET, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/packages/{s}/{s}", .{ name, version }), "", null);
}

fn field(fx: *Fx, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(fx.life.allocator(), ",\"source_commit\":{s}", .{extra});
}

test "a single publish stores a 40 or a 64 digit source_commit and getVersion serves it; without one the key is absent" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    try std.testing.expectEqual(@as(u16, 202), (try publishSingle(&fx, "pkg_a", "1.0.0", try field(&fx, q40))).status);
    try std.testing.expectEqual(@as(u16, 202), (try publishSingle(&fx, "pkg_b", "1.0.0", try field(&fx, q64))).status);
    try std.testing.expectEqual(@as(u16, 202), (try publishSingle(&fx, "pkg_c", "1.0.0", "")).status);
    try std.testing.expectEqualStrings(sha40, (try versionReply(&fx, "pkg_a", "1.0.0")).value.object.get("source_commit").?.string);
    try std.testing.expectEqualStrings(sha64, (try versionReply(&fx, "pkg_b", "1.0.0")).value.object.get("source_commit").?.string);
    const none = try versionReply(&fx, "pkg_c", "1.0.0");
    try std.testing.expectEqual(@as(u16, 200), none.status);
    try std.testing.expect(none.value.object.get("source_commit") == null);
}

test "a single commit refuses every invalid form of source_commit, and nothing is published" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    for (invalid_forms, 0..) |form, i| {
        const version = try std.fmt.allocPrint(fx.life.allocator(), "1.0.{d}", .{i});
        try expectCode(try publishSingle(&fx, "pkg_a", version, try field(&fx, form)), 400, "invalid_request");
        try expectCode(try versionReply(&fx, "pkg_a", version), 404, "version_not_found");
    }
}

test "the same single commit again resumes it; a repeat with another value, or none, is refused version_exists and the value stays" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const id = try begin(&fx, "pkg_a", "1.0.0", "bytes");
    const with = try field(&fx, q40);
    const first = try commitSingle(&fx, "pkg_a", "1.0.0", id, with);
    try std.testing.expectEqual(@as(u16, 202), first.status);
    const again = try commitSingle(&fx, "pkg_a", "1.0.0", id, with);
    try std.testing.expectEqual(@as(u16, 202), again.status);
    try std.testing.expectEqualStrings(first.value.object.get("publish_id").?.string, again.value.object.get("publish_id").?.string);
    try expectCode(try commitSingle(&fx, "pkg_a", "1.0.0", id, try field(&fx, qother)), 409, "version_exists");
    try expectCode(try commitSingle(&fx, "pkg_a", "1.0.0", id, ""), 409, "version_exists");
    for (0..3) |_| _ = try fx.call(.GET, first.value.object.get("status_url").?.string, "", fx.alice_token);
    try std.testing.expectEqualStrings(sha40, (try versionReply(&fx, "pkg_a", "1.0.0")).value.object.get("source_commit").?.string);
}

/// The commit body of the group `abc`: each member with its manifest hash and the text after it (`extras[i]`, with its leading comma, or "").
fn groupBody(fx: *Fx, extras: [3][]const u8) ![]const u8 {
    const a = fx.life.allocator();
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice("{\"members\":[");
    for (abc, extras, 0..) |n, extra, i| {
        if (i > 0) try out.append(',');
        try out.writer().print("{{\"name\":\"{s}\",\"manifest_sha256\":\"{s}\"{s}}}", .{ n, try fx.sha(n), extra });
    }
    try out.appendSlice("]}");
    return out.items;
}

fn commitPath(fx: *Fx, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/commit", .{id});
}

test "a group member's source_commit lands on that member's version only" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    const id = idOf(created);
    try fx.upload(created, "x");
    const body = try groupBody(&fx, .{ try field(&fx, q40), try field(&fx, q64), "" });
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try commitPath(&fx, id), body, fx.alice_token)).status);
    // Not served before the group is visible.
    try expectCode(try versionReply(&fx, "pkg_a", "1.0.0"), 404, "version_not_found");
    for (0..5) |_| _ = try fx.status(id);
    try std.testing.expectEqualStrings("visible", try fx.status(id));
    try std.testing.expectEqualStrings(sha40, (try versionReply(&fx, "pkg_a", "1.0.0")).value.object.get("source_commit").?.string);
    try std.testing.expectEqualStrings(sha64, (try versionReply(&fx, "pkg_b", "1.0.0")).value.object.get("source_commit").?.string);
    const c = try versionReply(&fx, "pkg_c", "1.0.0");
    try std.testing.expectEqual(@as(u16, 200), c.status);
    try std.testing.expect(c.value.object.get("source_commit") == null);
    try std.testing.expectEqualStrings(id, c.value.object.get("group_id").?.string);
}

test "a group commit refuses every invalid form on a member, naming it, and the group stays open" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    const id = idOf(created);
    try fx.upload(created, "x");
    for (invalid_forms) |form| {
        const r = try fx.call(.POST, try commitPath(&fx, id), try groupBody(&fx, .{ "", try field(&fx, form), "" }), fx.alice_token);
        try expectCode(r, 400, "invalid_request");
        try std.testing.expect(std.mem.indexOf(u8, r.body, "'source_commit' of 'pkg_b'") != null);
        try std.testing.expectEqualStrings("open", try fx.status(id));
    }
}

test "the same group commit again is accepted; one that differs only in a member's source_commit is refused group_commit_refused" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    const id = idOf(created);
    try fx.upload(created, "x");
    const with = try groupBody(&fx, .{ try field(&fx, q40), "", "" });
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try commitPath(&fx, id), with, fx.alice_token)).status);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try commitPath(&fx, id), with, fx.alice_token)).status);
    const differing = [_][3][]const u8{
        .{ try field(&fx, qother), "", "" },
        .{ "", "", "" },
        .{ try field(&fx, q40), try field(&fx, q40), "" },
    };
    for (differing) |extras| {
        try expectCode(try fx.call(.POST, try commitPath(&fx, id), try groupBody(&fx, extras), fx.alice_token), 409, "group_commit_refused");
    }
}
