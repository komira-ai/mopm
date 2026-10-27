//! Unit tests of what the fake shows beyond the group routes' basics (groups_test.zig has the fixture): the files of each member on
//! getGroup, the group of a version on getVersion, and a commit with `manifest_sha256` left out. Each test sends requests through
//! `api.handle` and reads the answers as a client would. The wire shapes themselves are held to the contract by //:contract_replay.

const std = @import("std");
const Value = std.json.Value;
const t = @import("groups_test.zig");
const Fx = t.Fx;
const Reply = t.Reply;
const abc = t.abc;
const idOf = t.idOf;
const expectCode = t.expectCode;
const uploadPath = t.uploadPath;

fn groupReply(fx: *Fx, id: []const u8, token: []const u8) !Reply {
    return fx.call(.GET, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{id}), "", token);
}

fn filesOfMember(r: Reply, i: usize) []const Value {
    return r.value.object.get("members").?.array.items[i].object.get("files").?.array.items;
}

test "getGroup lists each member's declared files, and says what is uploaded only while the group is open" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = fx.life.allocator();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    const id = idOf(created);
    // Store the first member's file only.
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try uploadPath(&fx, created, 0), "pkg_ax", null)).status);

    const open = try groupReply(&fx, id, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), open.status);
    for (abc, 0..) |n, i| {
        const files = filesOfMember(open, i);
        try std.testing.expectEqual(@as(usize, 1), files.len);
        const f = files[0].object;
        try std.testing.expectEqualStrings("noarch", f.get("subdir").?.string);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mojo-{s}-1.0.0-mojo1.0.0_0.conda", .{n}), f.get("filename").?.string);
        try std.testing.expectEqualStrings(try fx.sha(try std.fmt.allocPrint(a, "{s}x", .{n})), f.get("sha256").?.string);
        try std.testing.expectEqual(@as(i64, @intCast(n.len + 1)), f.get("size").?.integer);
        try std.testing.expectEqual(i == 0, f.get("uploaded").?.bool);
        // The declared facts and the flag, nothing else: no upload id and no URL.
        try std.testing.expectEqual(@as(usize, 5), f.count());
    }

    // Past open the facts stay and `uploaded` is gone, at every stage.
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try uploadPath(&fx, created, 1), "pkg_bx", null)).status);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try uploadPath(&fx, created, 2), "pkg_cx", null)).status);
    const commit = try std.fmt.allocPrint(a, "/api/v1/groups/{s}/commit", .{id});
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token)).status);
    for ([_][]const u8{ "validating", "committed", "visible" }) |want| {
        const r = try groupReply(&fx, id, fx.alice_token);
        try std.testing.expectEqualStrings(want, r.value.object.get("status").?.string);
        for (abc, 0..) |_, i| {
            const f = filesOfMember(r, i)[0].object;
            try std.testing.expectEqual(@as(usize, 4), f.count());
            try std.testing.expect(f.get("uploaded") == null);
        }
    }
}

test "getGroup of a group that ended keeps the facts; a number another group took leaves its member without files; the abort answer lists none" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = fx.life.allocator();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    const id = idOf(created);
    const aborted = try fx.call(.DELETE, try std.fmt.allocPrint(a, "/api/v1/groups/{s}", .{id}), "", fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), aborted.status);
    for (aborted.value.object.get("members").?.array.items) |m| try std.testing.expect(m.object.get("files") == null);

    const ended = try groupReply(&fx, id, fx.alice_token);
    try std.testing.expectEqualStrings("aborted", ended.value.object.get("status").?.string);
    for (abc, 0..) |_, i| {
        const f = filesOfMember(ended, i)[0].object;
        try std.testing.expectEqual(@as(usize, 4), f.count());
        try std.testing.expect(f.get("uploaded") == null);
    }

    // Another set takes pkg_a's number from the ended group.
    const second = try fx.call(.POST, "/api/v1/groups", try fx.request(&.{"pkg_a"}, "1.0.0", "y"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), second.status);
    const after = try groupReply(&fx, id, fx.alice_token);
    try std.testing.expectEqual(@as(usize, 0), filesOfMember(after, 0).len);
    try std.testing.expectEqual(@as(usize, 1), filesOfMember(after, 1).len);
    try std.testing.expectEqual(@as(usize, 1), filesOfMember(after, 2).len);

    // Bob owns pkg_a only: the first group is not his to see, and the answer says nothing of it.
    const hidden = try groupReply(&fx, id, fx.bob_token);
    try expectCode(hidden, 404, "group_not_found");
    try std.testing.expect(std.mem.indexOf(u8, hidden.body, "sha256") == null);
    try std.testing.expectEqual(@as(usize, 1), filesOfMember(try groupReply(&fx, idOf(second), fx.bob_token), 0).len);
}

/// A single publish of `name` at `version` with the bytes `content`: begin, PUT, commit (`manifest` is the text of a
/// `manifest_sha256` member of the commit body, with its leading comma, or ""), then the polls that finish it.
fn publishSingle(fx: *Fx, name: []const u8, version: []const u8, content: []const u8, manifest: []const u8) !Reply {
    const a = fx.life.allocator();
    const begin = try fx.call(.POST, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/{s}/files", .{ name, version }), try std.fmt.allocPrint(a,
        \\{{"subdir":"noarch","filename":"mojo-{s}-{s}-mojo1.0.0_0.conda","sha256":"{s}","size":{d}}}
    , .{ name, version, try fx.sha(content), content.len }), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), begin.status);
    const upload_id = begin.value.object.get("upload_id").?.string;
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try std.fmt.allocPrint(a, "/_fake/upload/{s}", .{upload_id}), content, null)).status);
    const body = try std.fmt.allocPrint(a, "{{\"upload_ids\":[\"{s}\"]{s}}}", .{ upload_id, manifest });
    const r = try fx.call(.POST, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/{s}/publish", .{ name, version }), body, fx.alice_token);
    if (r.status != 202) return r;
    const status_url = r.value.object.get("status_url").?.string;
    for (0..3) |_| _ = try fx.call(.GET, status_url, "", fx.alice_token);
    return r;
}

fn versionReply(fx: *Fx, name: []const u8, version: []const u8) !Reply {
    return fx.call(.GET, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/packages/{s}/{s}", .{ name, version }), "", null);
}

test "getVersion names the group that published a version, and nothing for a single publish; a pending member is not found" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    const id = idOf(created);
    try expectCode(try versionReply(&fx, "pkg_a", "1.0.0"), 404, "version_not_found");
    try fx.upload(created, "x");
    const commit = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/commit", .{id});
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token)).status);
    try expectCode(try versionReply(&fx, "pkg_a", "1.0.0"), 404, "version_not_found");
    _ = try fx.status(id);
    _ = try fx.status(id);
    try std.testing.expectEqualStrings("visible", try fx.status(id));
    for (abc) |n| {
        const v = try versionReply(&fx, n, "1.0.0");
        try std.testing.expectEqual(@as(u16, 200), v.status);
        try std.testing.expectEqualStrings(id, v.value.object.get("group_id").?.string);
    }

    // A version a single publish made has no group_id key.
    const single = try publishSingle(&fx, "pkg_a", "2.0.0", "single", "");
    try std.testing.expectEqual(@as(u16, 202), single.status);
    const v = try versionReply(&fx, "pkg_a", "2.0.0");
    try std.testing.expectEqual(@as(u16, 200), v.status);
    try std.testing.expectEqualStrings("published", v.value.object.get("state").?.string);
    try std.testing.expect(v.value.object.get("group_id") == null);
}

test "a single commit takes manifest_sha256 or leaves it out; a value that is given must be a hash" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = fx.life.allocator();
    // Left out: accepted, and the version holds a hash the fake chose (the sha256 of its first file).
    try std.testing.expectEqual(@as(u16, 202), (try publishSingle(&fx, "pkg_a", "1.0.0", "one", "")).status);
    const without = try versionReply(&fx, "pkg_a", "1.0.0");
    try std.testing.expectEqualStrings(try fx.sha("one"), without.value.object.get("manifest_sha256").?.string);
    // Given: kept as it is.
    const given = try std.fmt.allocPrint(a, ",\"manifest_sha256\":\"{s}\"", .{try fx.sha("manifest")});
    try std.testing.expectEqual(@as(u16, 202), (try publishSingle(&fx, "pkg_b", "1.0.0", "two", given)).status);
    try std.testing.expectEqualStrings(try fx.sha("manifest"), (try versionReply(&fx, "pkg_b", "1.0.0")).value.object.get("manifest_sha256").?.string);
    // Given but not a hash: invalid_request.
    for ([_][]const u8{ ",\"manifest_sha256\":\"abc\"", ",\"manifest_sha256\":7", ",\"manifest_sha256\":null" }) |bad| {
        try expectCode(try publishSingle(&fx, "pkg_c", "1.0.0", "three", bad), 400, "invalid_request");
    }
}

test "a group commit takes manifest_sha256 from some members and not from others; a repeat must say the same" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = fx.life.allocator();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    try fx.upload(created, "x");
    const commit = try std.fmt.allocPrint(a, "/api/v1/groups/{s}/commit", .{idOf(created)});
    // A value that is given must be a hash, whatever the others do.
    for ([_][]const u8{ "7", "null", "\"abc\"" }) |bad| {
        const body = try std.fmt.allocPrint(a, "{{\"members\":[{{\"name\":\"pkg_a\"}},{{\"name\":\"pkg_b\",\"manifest_sha256\":{s}}},{{\"name\":\"pkg_c\"}}]}}", .{bad});
        try expectCode(try fx.call(.POST, commit, body, fx.alice_token), 400, "invalid_request");
    }
    try std.testing.expectEqualStrings("open", try fx.status(idOf(created)));

    const mixed = try std.fmt.allocPrint(a, "{{\"members\":[{{\"name\":\"pkg_a\"}},{{\"name\":\"pkg_b\",\"manifest_sha256\":\"{s}\"}},{{\"name\":\"pkg_c\"}}]}}", .{try fx.sha("pkg_b")});
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, mixed, fx.alice_token)).status);
    // The same request again is the same; one that gives what the first left out is another request.
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, mixed, fx.alice_token)).status);
    try expectCode(try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token), 409, "group_commit_refused");
    _ = try fx.status(idOf(created));
    _ = try fx.status(idOf(created));
    try std.testing.expectEqualStrings("visible", try fx.status(idOf(created)));
    for (abc) |n| {
        const v = try versionReply(&fx, n, "1.0.0");
        try std.testing.expectEqualStrings(try fx.sha(try std.fmt.allocPrint(a, "{s}x", .{n})), v.value.object.get("manifest_sha256").?.string);
    }
}
