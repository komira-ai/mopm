//! Unit tests of the group routes (groups.zig), by behaviour: each test sends
//! requests through `api.handle`, as the server does, with no socket, and reads
//! the answers as a client would. The wire shapes themselves are held to the
//! contract by //:contract_replay.

const std = @import("std");
const Value = std.json.Value;
const api = @import("api.zig");
const st = @import("state.zig");

const Reply = struct { status: u16, body: []const u8, value: Value };

const Fx = struct {
    tmp: std.testing.TmpDir,
    life: std.heap.ArenaAllocator,
    state: st.State,
    alice: *st.User,
    bob: *st.User,
    alice_token: []const u8,
    bob_token: []const u8,
    session: []const u8,

    fn setup(fx: *Fx) !void {
        fx.tmp = std.testing.tmpDir(.{});
        fx.life = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = fx.life.allocator();
        const dir = try fx.tmp.dir.realpathAlloc(a, ".");
        fx.state = .{ .alloc = a, .base_url = "http://fake.test", .stage = "beta", .dir = dir };
        const s = &fx.state;
        fx.alice = try s.ensureUser("alice");
        fx.bob = try s.ensureUser("bob");
        for ([_][]const u8{ "pkg_a", "pkg_b", "pkg_c" }) |name| {
            const p = try s.addPackage(.{ .name = name, .created_at = s.now(), .updated_at = s.now(), .claim_expires_at = s.now() + st.claim_secs });
            try p.owners.append(a, fx.alice);
        }
        try s.packageByName("pkg_a").?.owners.append(a, fx.bob);
        const all: []const []const u8 = &.{ "pkg_a", "pkg_b", "pkg_c" };
        fx.alice_token = (try s.addToken(.{ .id = "t1", .secret = "alice-secret", .kind = .api, .user = fx.alice, .scopes = &.{ .publish, .yank }, .packages = all, .created_at = s.now(), .expires_at = s.now() + st.day })).secret;
        fx.bob_token = (try s.addToken(.{ .id = "t2", .secret = "bob-secret", .kind = .api, .user = fx.bob, .scopes = &.{.publish}, .packages = &.{"pkg_a"}, .created_at = s.now(), .expires_at = s.now() + st.day })).secret;
        fx.session = (try s.newSession(fx.alice, true)).secret;
        try @import("files.zig").rewrite(a, s);
    }

    fn deinit(fx: *Fx) void {
        fx.life.deinit();
        fx.tmp.cleanup();
    }

    /// One request, as the server serves it: everything the handler is given lives in an arena that is freed after the
    /// answer, so a record that kept a pointer into the request would read freed memory in the next call.
    fn call(fx: *Fx, method: std.http.Method, path: []const u8, body: []const u8, token: ?[]const u8) !Reply {
        const life = fx.life.allocator();
        var request_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer request_arena.deinit();
        const a = request_arena.allocator();
        var ctx = api.Ctx{
            .arena = a,
            .state = &fx.state,
            .method = method,
            .path = try a.dupe(u8, path),
            .query = "",
            .body = try a.dupe(u8, body),
            .authorization = if (token) |t| try std.fmt.allocPrint(a, "Bearer {s}", .{t}) else null,
        };
        const r = try api.handle(&ctx);
        const kept = try life.dupe(u8, r.body);
        const value = std.json.parseFromSliceLeaky(Value, life, kept, .{}) catch Value{ .null = {} };
        return .{ .status = @intFromEnum(r.status), .body = kept, .value = value };
    }

    fn sha(fx: *Fx, bytes: []const u8) ![]const u8 {
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
        return std.fmt.allocPrint(fx.life.allocator(), "{s}", .{std.fmt.fmtSliceHexLower(&d)});
    }

    /// A create request for pkg_a, pkg_b and pkg_c at `version`, with `bytes` as the content of each file.
    fn request(fx: *Fx, names: []const []const u8, version: []const u8, bytes: []const u8) ![]const u8 {
        const a = fx.life.allocator();
        var out = std.ArrayList(u8).init(a);
        try out.appendSlice("{\"members\":[");
        for (names, 0..) |n, i| {
            if (i > 0) try out.append(',');
            try out.writer().print(
                "{{\"name\":\"{s}\",\"version\":\"{s}\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"mojo-{s}-{s}-mojo1.0.0_0.conda\",\"sha256\":\"{s}\",\"size\":{d}}}]}}",
                .{ n, version, n, version, try fx.sha(try std.fmt.allocPrint(a, "{s}{s}", .{ n, bytes })), n.len + bytes.len },
            );
        }
        try out.appendSlice("]}");
        return out.items;
    }

    fn commitBody(fx: *Fx, names: []const []const u8) ![]const u8 {
        const a = fx.life.allocator();
        var out = std.ArrayList(u8).init(a);
        try out.appendSlice("{\"members\":[");
        for (names, 0..) |n, i| {
            if (i > 0) try out.append(',');
            try out.writer().print("{{\"name\":\"{s}\",\"manifest_sha256\":\"{s}\"}}", .{ n, try fx.sha(n) });
        }
        try out.appendSlice("]}");
        return out.items;
    }

    /// PUTs the bytes of every file the create answer asks for.
    fn upload(fx: *Fx, created: Reply, bytes: []const u8) !void {
        for (created.value.object.get("members").?.array.items) |m| {
            const name = m.object.get("name").?.string;
            for (m.object.get("files").?.array.items) |f| {
                if (f.object.get("uploaded").?.bool) continue;
                const path = try std.fmt.allocPrint(fx.life.allocator(), "/_fake/upload/{s}", .{f.object.get("upload_id").?.string});
                const content = try std.fmt.allocPrint(fx.life.allocator(), "{s}{s}", .{ name, bytes });
                const r = try fx.call(.PUT, path, content, null);
                try std.testing.expectEqual(@as(u16, 200), r.status);
            }
        }
    }

    fn status(fx: *Fx, id: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{id});
        const r = try fx.call(.GET, path, "", fx.alice_token);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        return r.value.object.get("status").?.string;
    }

    fn code(r: Reply) []const u8 {
        return r.value.object.get("error").?.object.get("code").?.string;
    }
};

const abc: []const []const u8 = &.{ "pkg_a", "pkg_b", "pkg_c" };

fn idOf(r: Reply) []const u8 {
    return r.value.object.get("group_id").?.string;
}

fn expectCode(r: Reply, status: u16, want: []const u8) !void {
    if (r.status != status or !std.mem.eql(u8, Fx.code(r), want)) {
        std.debug.print("want {d} {s}, got {d}: {s}\n", .{ status, want, r.status, r.body });
        return error.TestUnexpectedResult;
    }
}

fn versionsOf(fx: *Fx, name: []const u8) !usize {
    const path = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/packages/{s}/versions", .{name});
    const r = try fx.call(.GET, path, "", null);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    return r.value.object.get("versions").?.array.items.len;
}

/// Creates, uploads and commits the group of `abc` at `version`; returns its id.
fn commitAll(fx: *Fx, version: []const u8, bytes: []const u8) ![]const u8 {
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, version, bytes), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    try fx.upload(created, bytes);
    const path = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/commit", .{idOf(created)});
    const committed = try fx.call(.POST, path, try fx.commitBody(abc), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 202), committed.status);
    return idOf(created);
}

test "a three-package group is invisible until the group is visible, and then all of it is" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    try std.testing.expectEqualStrings("open", created.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 3), created.value.object.get("members").?.array.items.len);
    const first = created.value.object.get("members").?.array.items[0];
    try std.testing.expectEqualStrings("new", first.object.get("action").?.string);
    const file = first.object.get("files").?.array.items[0];
    try std.testing.expect(!file.object.get("uploaded").?.bool);
    try std.testing.expect(std.mem.startsWith(u8, file.object.get("put_url").?.string, "http://fake.test/_fake/upload/"));
    try std.testing.expect(file.object.get("put_headers").?.object.get("x-amz-checksum-sha256") != null);

    // Nothing the group reserved is visible, and uploading changes nothing.
    try fx.upload(created, "x");
    try std.testing.expectEqual(@as(usize, 0), try versionsOf(&fx, "pkg_a"));
    const id = idOf(created);
    const path = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/commit", .{id});
    const committed = try fx.call(.POST, path, try fx.commitBody(abc), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 202), committed.status);
    try std.testing.expectEqualStrings("validating", committed.value.object.get("status").?.string);
    try std.testing.expect(std.mem.startsWith(u8, committed.value.object.get("status_url").?.string, "/api/v1/groups/grp_"));

    // One stage per poll: a poll shows the stage the group is in, then moves it on. The members become visible with the
    // last move, all three at once.
    try std.testing.expectEqualStrings("validating", try fx.status(id));
    for (abc) |n| try std.testing.expectEqual(@as(usize, 0), try versionsOf(&fx, n));
    try std.testing.expectEqualStrings("committed", try fx.status(id));
    try std.testing.expectEqualStrings("visible", try fx.status(id));
    for (abc) |n| try std.testing.expectEqual(@as(usize, 1), try versionsOf(&fx, n));
    const shown = try fx.call(.GET, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{id}), "", fx.alice_token);
    try std.testing.expectEqualStrings("published", shown.value.object.get("members").?.array.items[2].object.get("state").?.string);
    try std.testing.expect(shown.value.object.get("committed_at") != null);
    try std.testing.expect(shown.value.object.get("failure") == null);
    const index = try fx.call(.GET, "/index/pk/g_/pkg_a", "", null);
    try std.testing.expectEqual(@as(u16, 200), index.status);
}

test "the same request is the same group; a resume offers URLs only for the files not yet stored" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const body = try fx.request(abc, "1.0.0", "x");
    const first = try fx.call(.POST, "/api/v1/groups", body, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), first.status);
    // Store the first member's file only.
    const m0 = first.value.object.get("members").?.array.items[0];
    const up = try std.fmt.allocPrint(fx.life.allocator(), "/_fake/upload/{s}", .{m0.object.get("files").?.array.items[0].object.get("upload_id").?.string});
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, up, "pkg_ax", null)).status);

    const again = try fx.call(.POST, "/api/v1/groups", body, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), again.status);
    try std.testing.expectEqualStrings(idOf(first), idOf(again));
    const members = again.value.object.get("members").?.array.items;
    try std.testing.expectEqualStrings("join", members[0].object.get("action").?.string);
    try std.testing.expect(members[0].object.get("files").?.array.items[0].object.get("uploaded").?.bool);
    try std.testing.expect(members[0].object.get("files").?.array.items[0].object.get("put_url") == null);
    try std.testing.expect(!members[1].object.get("files").?.array.items[0].object.get("uploaded").?.bool);
    // The member order in the request does not name another group.
    const reversed = try fx.request(&.{ "pkg_c", "pkg_b", "pkg_a" }, "1.0.0", "x");
    try std.testing.expectEqualStrings(idOf(first), idOf(try fx.call(.POST, "/api/v1/groups", reversed, fx.alice_token)));
    // Another set of bytes is another group; it supersedes the open one that shares its versions.
    const other = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "y"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), other.status);
    try std.testing.expect(!std.mem.eql(u8, idOf(first), idOf(other)));
    try std.testing.expectEqualStrings("superseded", try fx.status(idOf(first)));
}

/// A create request for `name` at `version` whose one file has the bytes `content`, and the path that file is PUT to.
fn declareOne(fx: *Fx, name: []const u8, version: []const u8, filename_name: []const u8, content: []const u8) ![]const u8 {
    return std.fmt.allocPrint(fx.life.allocator(),
        \\{{"name":"{s}","version":"{s}","files":[{{"subdir":"noarch","filename":"mojo-{s}-{s}-mojo1.0.0_0.conda","sha256":"{s}","size":{d}}}]}}
    , .{ name, version, filename_name, version, try fx.sha(content), content.len });
}

fn uploadPath(fx: *Fx, created: Reply, member: usize) ![]const u8 {
    const m = created.value.object.get("members").?.array.items[member];
    return std.fmt.allocPrint(fx.life.allocator(), "/_fake/upload/{s}", .{m.object.get("files").?.array.items[0].object.get("upload_id").?.string});
}

test "one rejected member ends the group rejected and nothing is visible" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = fx.life.allocator();
    // pkg_b's file holds a marker the fake reads as a rejection (it does not open archives).
    const bad = "REJECT:path_not_allowed";
    const declared = try std.fmt.allocPrint(a, "{{\"members\":[{s},{s}]}}", .{
        try declareOne(&fx, "pkg_a", "2.0.0", "pkg_a", "fine"),
        try declareOne(&fx, "pkg_b", "2.0.0", "pkg_b", bad),
    });
    const g = try fx.call(.POST, "/api/v1/groups", declared, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), g.status);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try uploadPath(&fx, g, 0), "fine", null)).status);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try uploadPath(&fx, g, 1), bad, null)).status);
    const id = idOf(g);
    const commit = try std.fmt.allocPrint(a, "/api/v1/groups/{s}/commit", .{id});
    const names: []const []const u8 = &.{ "pkg_a", "pkg_b" };
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, try fx.commitBody(names), fx.alice_token)).status);
    try std.testing.expectEqualStrings("validating", try fx.status(id));
    try std.testing.expectEqualStrings("rejected", try fx.status(id));
    const ended = try fx.call(.GET, try std.fmt.allocPrint(a, "/api/v1/groups/{s}", .{id}), "", fx.alice_token);
    const failure = ended.value.object.get("failure").?.object;
    try std.testing.expectEqualStrings("path_not_allowed", failure.get("code").?.string);
    try std.testing.expectEqualStrings("pkg_b", failure.get("member").?.string);
    try std.testing.expectEqual(@as(usize, 0), try versionsOf(&fx, "pkg_a"));
    try std.testing.expectEqual(@as(usize, 0), try versionsOf(&fx, "pkg_b"));
    // The numbers are free again: the same request opens the group again, as the next attempt.
    const reopened = try fx.call(.POST, "/api/v1/groups", declared, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), reopened.status);
    try std.testing.expectEqual(@as(i64, 2), reopened.value.object.get("attempt").?.integer);
    try std.testing.expectEqualStrings("open", reopened.value.object.get("status").?.string);

    // A file named for another package is rejected too.
    const wrong = try fx.call(.POST, "/api/v1/groups", try std.fmt.allocPrint(a, "{{\"members\":[{s}]}}", .{try declareOne(&fx, "pkg_c", "2.0.0", "pkg_other", "fine")}), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), wrong.status);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try uploadPath(&fx, wrong, 0), "fine", null)).status);
    const only_c: []const []const u8 = &.{"pkg_c"};
    const commit_c = try std.fmt.allocPrint(a, "/api/v1/groups/{s}/commit", .{idOf(wrong)});
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit_c, try fx.commitBody(only_c), fx.alice_token)).status);
    _ = try fx.status(idOf(wrong));
    try std.testing.expectEqualStrings("rejected", try fx.status(idOf(wrong)));
    const wrong_view = try fx.call(.GET, try std.fmt.allocPrint(a, "/api/v1/groups/{s}", .{idOf(wrong)}), "", fx.alice_token);
    try std.testing.expectEqualStrings("filename_mismatch", wrong_view.value.object.get("failure").?.object.get("code").?.string);
}

test "an expired group is refused at commit, and the same request opens it again" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const body = try fx.request(abc, "1.0.0", "x");
    const created = try fx.call(.POST, "/api/v1/groups", body, fx.alice_token);
    try fx.upload(created, "x");
    _ = try fx.call(.POST, "/_fake/clock", "{\"advance_seconds\":43200}", null);
    const commit = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/commit", .{idOf(created)});
    const refused = try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token);
    try expectCode(refused, 409, "group_commit_refused");
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "expired at") != null);
    try std.testing.expectEqualStrings("expired", try fx.status(idOf(created)));
    try std.testing.expectEqual(@as(usize, 0), try versionsOf(&fx, "pkg_a"));
    // Aborting an expired group is not allowed; creating it again opens the next attempt, with the files still stored.
    try expectCode(try fx.call(.DELETE, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{idOf(created)}), "", fx.alice_token), 409, "group_not_open");
    const again = try fx.call(.POST, "/api/v1/groups", body, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), again.status);
    try std.testing.expectEqual(@as(i64, 2), again.value.object.get("attempt").?.integer);
    try std.testing.expect(again.value.object.get("members").?.array.items[0].object.get("files").?.array.items[0].object.get("uploaded").?.bool);
}

test "commit: what it checks, and that a repeat of it is the same commit" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    const commit = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/commit", .{idOf(created)});
    // Files not in storage.
    try expectCode(try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token), 400, "upload_invalid");
    try fx.upload(created, "x");
    // Malformed requests.
    const bad_bodies = [_][]const u8{
        "",
        "[]",
        "{}",
        "{\"members\":{}}",
        "{\"members\":[1]}",
        "{\"members\":[{}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"manifest_sha256\":\"zz\"}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"manifest_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}]}",
        "{\"members\":[{\"name\":\"nope\",\"manifest_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"manifest_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"readme\":3}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"manifest_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"license\":\"\"}]}",
    };
    for (bad_bodies) |b| try expectCode(try fx.call(.POST, commit, b, fx.alice_token), 400, "invalid_request");
    var twice = std.ArrayList(u8).init(fx.life.allocator());
    try twice.writer().print("{{\"members\":[{{\"name\":\"pkg_a\",\"manifest_sha256\":\"{s}\"}},{{\"name\":\"pkg_a\",\"manifest_sha256\":\"{s}\"}}]}}", .{ try fx.sha("a"), try fx.sha("a") });
    try expectCode(try fx.call(.POST, commit, twice.items, fx.alice_token), 400, "invalid_request");

    // The display fields are taken; a repeat of the request in another member order is the same request.
    const with_display = try std.fmt.allocPrint(fx.life.allocator(),
        \\{{"members":[{{"name":"pkg_c","manifest_sha256":"{s}","description":"d","license":"MIT","readme":"# c"}},{{"name":"pkg_b","manifest_sha256":"{s}"}},{{"name":"pkg_a","manifest_sha256":"{s}"}}]}}
    , .{ try fx.sha("pkg_c"), try fx.sha("pkg_b"), try fx.sha("pkg_a") });
    const reordered = try std.fmt.allocPrint(fx.life.allocator(),
        \\{{"members":[{{"name":"pkg_a","manifest_sha256":"{s}"}},{{"name":"pkg_b","manifest_sha256":"{s}"}},{{"name":"pkg_c","manifest_sha256":"{s}","description":"d","license":"MIT","readme":"# c"}}]}}
    , .{ try fx.sha("pkg_a"), try fx.sha("pkg_b"), try fx.sha("pkg_c") });
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, with_display, fx.alice_token)).status);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, reordered, fx.alice_token)).status);
    try expectCode(try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token), 409, "group_commit_refused");
    _ = try fx.status(idOf(created));
    _ = try fx.status(idOf(created));
    try std.testing.expectEqualStrings("visible", try fx.status(idOf(created)));
    // A committed group answers 200 as it is; a different request is still refused.
    const done = try fx.call(.POST, commit, with_display, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), done.status);
    try std.testing.expectEqualStrings("visible", done.value.object.get("status").?.string);
    try expectCode(try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token), 409, "group_commit_refused");
}

test "an open group is aborted, once or twice, and a group past open cannot be" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    const path = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{idOf(created)});
    const aborted = try fx.call(.DELETE, path, "", fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), aborted.status);
    try std.testing.expectEqualStrings("aborted", aborted.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.DELETE, path, "", fx.alice_token)).status);
    const commit = try std.fmt.allocPrint(fx.life.allocator(), "{s}/commit", .{path});
    try expectCode(try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token), 409, "group_commit_refused");

    const id = try commitAll(&fx, "1.0.0", "x");
    const ongoing = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{id});
    const refused = try fx.call(.DELETE, ongoing, "", fx.alice_token);
    try expectCode(refused, 409, "group_not_open");
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "is validating") != null);
}

test "a group is yanked and unyanked, and only what the yank changed is restored" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const id = try commitAll(&fx, "1.0.0", "x");
    const path = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{id});
    const yank = try std.fmt.allocPrint(fx.life.allocator(), "{s}/yank", .{path});
    // Not before it is visible.
    try expectCode(try fx.call(.PUT, yank, "{\"yanked\":true,\"reason\":\"bad\"}", fx.alice_token), 409, "group_not_settled");
    _ = try fx.status(id);
    _ = try fx.status(id);
    try std.testing.expectEqualStrings("visible", try fx.status(id));
    // A member yanked by hand before the group's yank.
    const by_hand = try fx.call(.PUT, "/api/v1/packages/pkg_b/1.0.0/yank", "{\"yanked\":true,\"reason\":\"by hand\"}", fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), by_hand.status);

    try expectCode(try fx.call(.PUT, yank, "{\"yanked\":true}", fx.alice_token), 400, "invalid_request");
    try expectCode(try fx.call(.PUT, yank, "{\"yanked\":\"yes\"}", fx.alice_token), 400, "invalid_request");
    try expectCode(try fx.call(.PUT, yank, "", fx.alice_token), 400, "invalid_request");
    const started = try fx.call(.PUT, yank, "{\"yanked\":true,\"reason\":\"broken build\"}", fx.alice_token);
    try std.testing.expectEqual(@as(u16, 202), started.status);
    try std.testing.expectEqualStrings("yanking", started.value.object.get("yank").?.object.get("state").?.string);
    // Asked again while it runs: the same answer.
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.PUT, yank, "{\"yanked\":true,\"reason\":\"broken build\"}", fx.alice_token)).status);
    try expectCode(try fx.call(.PUT, yank, "{\"yanked\":false}", fx.alice_token), 409, "group_not_settled");
    _ = try fx.call(.GET, path, "", fx.alice_token);
    const yanked = try fx.call(.GET, path, "", fx.alice_token);
    const yank_view = yanked.value.object.get("yank").?.object;
    try std.testing.expectEqualStrings("yanked", yank_view.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 2), yank_view.get("yanked_members").?.integer);
    try std.testing.expectEqualStrings("broken build", yank_view.get("reason").?.string);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, yank, "{\"yanked\":true,\"reason\":\"again\"}", fx.alice_token)).status);
    const a = try fx.call(.GET, "/api/v1/packages/pkg_a/1.0.0", "", null);
    try std.testing.expectEqualStrings("yanked", a.value.object.get("state").?.string);

    const unyank = try fx.call(.PUT, yank, "{\"yanked\":false}", fx.alice_token);
    try std.testing.expectEqual(@as(u16, 202), unyank.status);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.PUT, yank, "{\"yanked\":false}", fx.alice_token)).status);
    try expectCode(try fx.call(.PUT, yank, "{\"yanked\":true,\"reason\":\"x\"}", fx.alice_token), 409, "group_not_settled");
    _ = try fx.call(.GET, path, "", fx.alice_token);
    const restored = try fx.call(.GET, path, "", fx.alice_token);
    try std.testing.expectEqualStrings("restored", restored.value.object.get("yank").?.object.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 2), restored.value.object.get("yank").?.object.get("yanked_members").?.integer);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, yank, "{\"yanked\":false}", fx.alice_token)).status);
    try std.testing.expectEqualStrings("published", (try fx.call(.GET, "/api/v1/packages/pkg_a/1.0.0", "", null)).value.object.get("state").?.string);
    try std.testing.expectEqualStrings("yanked", (try fx.call(.GET, "/api/v1/packages/pkg_b/1.0.0", "", null)).value.object.get("state").?.string);
    try std.testing.expectEqualStrings("published", (try fx.call(.GET, "/api/v1/packages/pkg_c/1.0.0", "", null)).value.object.get("state").?.string);
    // A restored group can be yanked again.
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.PUT, yank, "{\"yanked\":true,\"reason\":\"second\"}", fx.alice_token)).status);
    // A group that was never yanked has nothing to restore.
    const other = try commitAll(&fx, "2.0.0", "y");
    _ = try fx.status(other);
    _ = try fx.status(other);
    try std.testing.expectEqualStrings("visible", try fx.status(other));
    const other_yank = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/yank", .{other});
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, other_yank, "{\"yanked\":false}", fx.alice_token)).status);
}

test "who may create, see, commit and yank a group" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const body = try fx.request(abc, "1.0.0", "x");
    try expectCode(try fx.call(.POST, "/api/v1/groups", body, null), 401, "token_missing");
    try expectCode(try fx.call(.POST, "/api/v1/groups", body, fx.session), 403, "scope_missing");
    // Bob's token covers pkg_a only: the first member it does not cover is named.
    const refused = try fx.call(.POST, "/api/v1/groups", body, fx.bob_token);
    try expectCode(refused, 403, "scope_missing");
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "'pkg_b'") != null);
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(&.{"pkg_z"}, "1.0.0", "x"), fx.alice_token), 403, "scope_missing");
    // A token that covers a package its account does not own.
    const mallory = try fx.state.ensureUser("mallory");
    _ = try fx.state.addToken(.{ .id = "t3", .secret = "mallory-secret", .kind = .api, .user = mallory, .scopes = &.{.publish}, .packages = &.{"pkg_c"}, .created_at = fx.state.now(), .expires_at = fx.state.now() + st.day });
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(&.{"pkg_c"}, "1.0.0", "x"), "mallory-secret"), 403, "not_owner");
    // A package that does not exist, covered by a token that names it.
    _ = try fx.state.addToken(.{ .id = "t4", .secret = "ghost-secret", .kind = .api, .user = fx.alice, .scopes = &.{.publish}, .packages = &.{"pkg_z"}, .created_at = fx.state.now(), .expires_at = fx.state.now() + st.day });
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(&.{"pkg_z"}, "1.0.0", "x"), "ghost-secret"), 404, "package_not_found");

    const only_a: []const []const u8 = &.{"pkg_a"};
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(only_a, "1.0.0", "x"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    const path = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{idOf(created)});
    // Bob owns every package in the group (pkg_a): he may see it. Mallory may not, and neither may a session.
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.GET, path, "", fx.bob_token)).status);
    try expectCode(try fx.call(.GET, path, "", "mallory-secret"), 404, "group_not_found");
    try expectCode(try fx.call(.GET, path, "", fx.session), 403, "scope_missing");
    try expectCode(try fx.call(.GET, "/api/v1/groups/nope", "", fx.alice_token), 404, "group_not_found");
    try expectCode(try fx.call(.GET, "/api/v1/groups/grp_00000000000000000000000000000000", "", fx.alice_token), 404, "group_not_found");
    // Bob's own create of the same version meets alice's open group.
    const conflict = try fx.call(.POST, "/api/v1/groups", try fx.request(only_a, "1.0.0", "other"), fx.bob_token);
    try expectCode(conflict, 409, "group_conflict");
    try std.testing.expect(std.mem.indexOf(u8, conflict.body, "is held by group") != null);
}

test "a version that exists is version_exists; a single publish does not join a group's number" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const only_a: []const []const u8 = &.{"pkg_a"};
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(only_a, "1.0.0", "x"), fx.alice_token);
    // A single publish of the number the open group holds.
    const begin = try fx.call(.POST, "/api/v1/packages/pkg_a/1.0.0/files", try std.fmt.allocPrint(fx.life.allocator(),
        \\{{"subdir":"noarch","filename":"mojo-pkg_a-1.0.0-mojo1.0.0_0.conda","sha256":"{s}","size":2}}
    , .{try fx.sha("zz")}), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), begin.status);
    _ = try fx.call(.PUT, try std.fmt.allocPrint(fx.life.allocator(), "/_fake/upload/{s}", .{begin.value.object.get("upload_id").?.string}), "zz", null);
    const single = try std.fmt.allocPrint(fx.life.allocator(), "{{\"upload_ids\":[\"{s}\"],\"manifest_sha256\":\"{s}\"}}", .{ begin.value.object.get("upload_id").?.string, try fx.sha("m") });
    try expectCode(try fx.call(.POST, "/api/v1/packages/pkg_a/1.0.0/publish", single, fx.alice_token), 409, "version_exists");
    // Once the group has ended, the single takes the number.
    _ = try fx.call(.DELETE, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{idOf(created)}), "", fx.alice_token);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, "/api/v1/packages/pkg_a/1.0.0/publish", single, fx.alice_token)).status);
    // And the group cannot now: the number is held by a publish.
    const again = try fx.call(.POST, "/api/v1/groups", try fx.request(only_a, "1.0.0", "x"), fx.alice_token);
    try expectCode(again, 409, "version_exists");
}

test "a group whose number is a published version's is refused whole, naming it" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const id = try commitAll(&fx, "1.0.0", "x");
    _ = try fx.status(id);
    _ = try fx.status(id);
    try std.testing.expectEqualStrings("visible", try fx.status(id));
    const refused = try fx.call(.POST, "/api/v1/groups", try fx.request(&.{ "pkg_a", "pkg_b" }, "1.0.0", "other"), fx.alice_token);
    try expectCode(refused, 409, "version_exists");
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "'pkg_a' 1.0.0 already exists") != null);
    // The same request that made it is the group, as it is.
    const same = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), same.status);
    try std.testing.expectEqualStrings("visible", same.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("skip_identical", same.value.object.get("members").?.array.items[0].object.get("action").?.string);
}

test "group publishing off, read-only mode, and the limits of a request" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const body = try fx.request(abc, "1.0.0", "x");
    const created = try fx.call(.POST, "/api/v1/groups", body, fx.alice_token);
    const path = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{idOf(created)});

    _ = try fx.call(.POST, "/_fake/mode", "{\"read_only\":true}", null);
    try expectCode(try fx.call(.POST, "/api/v1/groups", body, fx.alice_token), 503, "read_only_mode");
    try expectCode(try fx.call(.POST, try std.fmt.allocPrint(fx.life.allocator(), "{s}/commit", .{path}), try fx.commitBody(abc), fx.alice_token), 503, "read_only_mode");
    try expectCode(try fx.call(.PUT, try std.fmt.allocPrint(fx.life.allocator(), "{s}/yank", .{path}), "{\"yanked\":false}", fx.alice_token), 503, "read_only_mode");
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.GET, path, "", fx.alice_token)).status);
    _ = try fx.call(.POST, "/_fake/mode", "{\"read_only\":false}", null);

    _ = try fx.call(.POST, "/_fake/groups", "{\"enabled\":false}", null);
    try expectCode(try fx.call(.POST, "/api/v1/groups", body, fx.alice_token), 404, "route_not_found");
    // A group that exists is still shown.
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.GET, path, "", fx.alice_token)).status);
    _ = try fx.call(.POST, "/_fake/groups", "{\"enabled\":true}", null);
    try expectCode(try fx.call(.POST, "/_fake/groups", "{}", null), 400, "invalid_request");

    // A fault set through the controls answers before the handler.
    _ = try fx.call(.POST, "/_fake/fault", "{\"operation\":\"createGroup\",\"code\":\"rate_limited\"}", null);
    try expectCode(try fx.call(.POST, "/api/v1/groups", body, fx.alice_token), 429, "rate_limited");

    const refusals = [_][]const u8{
        "",
        "{}",
        "{\"members\":3}",
        "{\"members\":[]}",
        "{\"members\":[3]}",
        "{\"members\":[{\"name\":\"pkg_a\"}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\"}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[]}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[3]}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{}]}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{\"subdir\":\"win-64\"}]}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{\"subdir\":\"noarch\"}]}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"x.tar\"}]}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"mojo-a.conda\"}]}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"mojo-a.conda\",\"sha256\":\"ab\"}]}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"mojo-a.conda\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}]}]}",
        "{\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"mojo-a.conda\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"size\":0}]}]}",
    };
    for (refusals) |b| try expectCode(try fx.call(.POST, "/api/v1/groups", b, fx.alice_token), 400, "invalid_request");
    const file = "{\"subdir\":\"noarch\",\"filename\":\"mojo-pkg_a-1.0.0-mojo1.0.0_0.conda\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"size\":1}";
    const too_big = try std.fmt.allocPrint(fx.life.allocator(), "{{\"members\":[{{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{s}]}}]}}", .{file[0 .. file.len - 2] ++ "100000001}"});
    try expectCode(try fx.call(.POST, "/api/v1/groups", too_big, fx.alice_token), 413, "payload_too_large");
    const bad_name = try std.fmt.allocPrint(fx.life.allocator(), "{{\"members\":[{{\"name\":\"Pkg\",\"version\":\"1.0.0\",\"files\":[{s}]}}]}}", .{file});
    try expectCode(try fx.call(.POST, "/api/v1/groups", bad_name, fx.alice_token), 400, "invalid_name");
    const bad_version = try std.fmt.allocPrint(fx.life.allocator(), "{{\"members\":[{{\"name\":\"pkg_a\",\"version\":\"1.0\",\"files\":[{s}]}}]}}", .{file});
    try expectCode(try fx.call(.POST, "/api/v1/groups", bad_version, fx.alice_token), 400, "invalid_version");
    const twice = try std.fmt.allocPrint(fx.life.allocator(), "{{\"members\":[{{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{s}]}},{{\"name\":\"pkg_a\",\"version\":\"1.0.1\",\"files\":[{s}]}}]}}", .{ file, file });
    try expectCode(try fx.call(.POST, "/api/v1/groups", twice, fx.alice_token), 400, "invalid_request");
    const same_file = try std.fmt.allocPrint(fx.life.allocator(), "{{\"members\":[{{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"files\":[{s},{s}]}}]}}", .{ file, file });
    try expectCode(try fx.call(.POST, "/api/v1/groups", same_file, fx.alice_token), 400, "invalid_request");
    // The per-package byte limit.
    _ = try fx.call(.POST, "/_fake/limits", "{\"project_bytes\":1}", null);
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(&.{"pkg_c"}, "9.0.0", "xx"), fx.alice_token), 403, "limit_exceeded");
}

test "the open groups of a caller are capped; a group that shares a version with an open one replaces it" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    // Five open groups of one caller, each of its own package version (they share none).
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const version = try std.fmt.allocPrint(fx.life.allocator(), "{d}.0.0", .{i + 1});
        const r = try fx.call(.POST, "/api/v1/groups", try fx.request(&.{"pkg_a"}, version, "x"), fx.alice_token);
        try std.testing.expectEqual(@as(u16, 201), r.status);
    }
    const sixth = try fx.call(.POST, "/api/v1/groups", try fx.request(&.{"pkg_b"}, "1.0.0", "x"), fx.alice_token);
    try expectCode(sixth, 409, "group_conflict");
    try std.testing.expect(std.mem.indexOf(u8, sixth.body, "at most 5") != null);
    // A group that shares a version with one of them supersedes it, so it does not need a sixth place.
    const many = try fx.call(.POST, "/api/v1/groups", try fx.request(&.{"pkg_a"}, "1.0.0", "y"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), many.status);
}

test "the controls: a PUT that fails once, and time that passes between the create and the commit" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const body = try fx.request(abc, "1.0.0", "x");
    const created = try fx.call(.POST, "/api/v1/groups", body, fx.alice_token);
    // After one more PUT, the next one answers unavailable, once.
    try expectCode(try fx.call(.POST, "/_fake/put_fault", "{\"after\":-1}", null), 400, "invalid_request");
    try expectCode(try fx.call(.POST, "/_fake/put_fault", "{}", null), 400, "invalid_request");
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.POST, "/_fake/put_fault", "{\"after\":1}", null)).status);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try uploadPath(&fx, created, 0), "pkg_ax", null)).status);
    try expectCode(try fx.call(.PUT, try uploadPath(&fx, created, 1), "pkg_bx", null), 503, "unavailable");
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try uploadPath(&fx, created, 1), "pkg_bx", null)).status);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try uploadPath(&fx, created, 2), "pkg_cx", null)).status);

    // The clock jumps when the commit arrives: the group is past its deadline by then.
    try expectCode(try fx.call(.POST, "/_fake/commit_clock", "{\"advance_seconds\":-1}", null), 400, "invalid_request");
    try expectCode(try fx.call(.POST, "/_fake/commit_clock", "{}", null), 400, "invalid_request");
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.POST, "/_fake/commit_clock", "{\"advance_seconds\":43200}", null)).status);
    const commit = try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/commit", .{idOf(created)});
    const refused = try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token);
    try expectCode(refused, 409, "group_commit_refused");
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "expired at") != null);
    // Once: the jump does not repeat, and opening the group again gives it a deadline from the new time.
    const again = try fx.call(.POST, "/api/v1/groups", body, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), again.status);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token)).status);
}

/// A JWT-shaped CI identity token whose payload names `repository` (the fake reads no signature).
fn jwtOf(fx: *Fx, repository: []const u8) ![]const u8 {
    const a = fx.life.allocator();
    const enc = std.base64.url_safe_no_pad.Encoder;
    const payload = try std.fmt.allocPrint(a, "{{\"repository\":\"{s}\"}}", .{repository});
    const part = try a.alloc(u8, enc.calcSize(payload.len));
    _ = enc.encode(part, payload);
    return std.fmt.allocPrint(a, "e30.{s}.c2ln", .{part});
}

fn exchange(fx: *Fx, jwt: []const u8, packages: []const u8) !Reply {
    const body = try std.fmt.allocPrint(fx.life.allocator(), "{{\"jwt\":\"{s}\",\"packages\":{s}}}", .{ jwt, packages });
    return fx.call(.POST, "/api/v1/auth/oidc/exchange", body, null);
}

test "the packages exchange: who it is for, what it refuses, and that nothing is made by a refusal" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const jwt = try jwtOf(&fx, "org/repo");
    const one = "[{\"name\":\"new_one\",\"version\":\"1.0.0\"}]";

    // A repository nobody configured is not a CI publisher, however well-formed the token and the list.
    try expectCode(try exchange(&fx, jwt, one), 403, "oidc_not_trusted");
    try fx.state.ci_repos.append(fx.life.allocator(), "org/repo");

    // The list is checked before the token: each of these is the caller's mistake.
    try expectCode(try exchange(&fx, jwt, "{}"), 400, "invalid_request");
    try expectCode(try exchange(&fx, jwt, "[]"), 400, "invalid_request");
    try expectCode(try exchange(&fx, jwt, "[1]"), 400, "invalid_request");
    try expectCode(try exchange(&fx, jwt, "[{\"version\":\"1.0.0\"}]"), 400, "invalid_request");
    try expectCode(try exchange(&fx, jwt, "[{\"name\":\"new_one\"}]"), 400, "invalid_request");
    try expectCode(try exchange(&fx, jwt, "[{\"name\":\"Not A Name\",\"version\":\"1.0.0\"}]"), 400, "invalid_name");
    try expectCode(try exchange(&fx, jwt, "[{\"name\":\"new_one\",\"version\":\"one\"}]"), 400, "invalid_version");
    try expectCode(try exchange(&fx, jwt, "[{\"name\":\"new_one\",\"version\":\"1.0.0\"},{\"name\":\"new_one\",\"version\":\"1.0.1\"}]"), 400, "invalid_request");
    var many = std.ArrayList(u8).init(fx.life.allocator());
    try many.append('[');
    for (0..101) |i| try many.writer().print("{s}{{\"name\":\"many_{d}\",\"version\":\"1.0.0\"}}", .{ if (i == 0) "" else ",", i });
    try many.append(']');
    try expectCode(try exchange(&fx, jwt, many.items), 400, "invalid_request");
    const both = try std.fmt.allocPrint(fx.life.allocator(), "{{\"jwt\":\"{s}\",\"name\":\"new_one\",\"version\":\"1.0.0\",\"packages\":{s}}}", .{ jwt, one });
    try expectCode(try fx.call(.POST, "/api/v1/auth/oidc/exchange", both, null), 400, "invalid_request");
    try expectCode(try fx.call(.POST, "/api/v1/auth/oidc/exchange", "{\"jwt\":\"x\",\"packages\":3}", null), 400, "invalid_request");
    try expectCode(try exchange(&fx, "not-a-jwt", one), 401, "oidc_token_invalid");

    // A name someone else owns refuses the whole list, and the name before it is not created.
    try expectCode(try exchange(&fx, jwt, "[{\"name\":\"new_one\",\"version\":\"1.0.0\"},{\"name\":\"pkg_a\",\"version\":\"1.0.0\"}]"), 403, "not_owner");
    try std.testing.expect(fx.state.packageByName("new_one") == null);
    // No token was minted by any refusal: the fixture's two API tokens and its session are all there are.
    try std.testing.expectEqual(@as(usize, 3), fx.state.tokens.items.len);
}

test "a packages token creates and runs a group of exactly its versions, and no other" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = fx.life.allocator();
    try fx.state.ci_repos.append(a, "org/repo");
    const jwt = try jwtOf(&fx, "org/repo");
    const names: []const []const u8 = &.{ "new_one", "new_two" };

    const minted = try exchange(&fx, jwt, "[{\"name\":\"new_one\",\"version\":\"1.0.0\"},{\"name\":\"new_two\",\"version\":\"1.0.0\"}]");
    try std.testing.expectEqual(@as(u16, 200), minted.status);
    try std.testing.expectEqualStrings("publish", minted.value.object.get("token_kind").?.string);
    try std.testing.expectEqual(@as(usize, 2), minted.value.object.get("packages").?.array.items.len);
    try std.testing.expect(minted.value.object.get("name") == null);
    const token = minted.value.object.get("token").?.string;
    const publisher = fx.state.userByHandle("ci/org/repo").?;
    try std.testing.expect(fx.state.packageByName("new_one").?.isOwner(publisher));

    // The token is not for a version or a package it does not name.
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(names, "2.0.0", "x"), token), 403, "scope_missing");
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(&.{ "new_one", "pkg_a" }, "1.0.0", "x"), token), 403, "scope_missing");

    // It creates the group, and the group runs to visible under it.
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(names, "1.0.0", "x"), token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    try fx.upload(created, "x");
    const commit = try std.fmt.allocPrint(a, "/api/v1/groups/{s}/commit", .{idOf(created)});
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, try fx.commitBody(names), token)).status);
    const poll = try std.fmt.allocPrint(a, "/api/v1/groups/{s}", .{idOf(created)});
    var last: []const u8 = "";
    for (0..4) |_| last = (try fx.call(.GET, poll, "", token)).value.object.get("status").?.string;
    try std.testing.expectEqualStrings("visible", last);
    try std.testing.expectEqual(@as(usize, 1), try versionsOf(&fx, "new_one"));
    try std.testing.expectEqual(@as(usize, 1), try versionsOf(&fx, "new_two"));
}
