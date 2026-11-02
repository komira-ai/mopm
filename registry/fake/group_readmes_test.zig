//! Unit tests of readmes as uploaded objects (group_readmes.zig; the fixture is groups_test.zig's). Each test sends requests through
//! `api.handle` and reads the answers as a client would. The wire shapes themselves are held to the contract by //:contract_replay.

const std = @import("std");
const Value = std.json.Value;
const t = @import("groups_test.zig");
const st = @import("state.zig");
const files = @import("files.zig");
const Fx = t.Fx;
const Reply = t.Reply;
const abc = t.abc;
const idOf = t.idOf;
const expectCode = t.expectCode;

const text_for = [_][]const u8{ "# pkg_a\nthe first\n", "# pkg_b\nthe second\n", "\xEF\xBB\xBF# pkg_c with a byte order mark and \xC3\xA9\n" };

fn refJson(fx: *Fx, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(fx.life.allocator(), "{{\"sha256\":\"{s}\",\"size\":{d}}}", .{ try fx.sha(text), text.len });
}

/// A create request for `abc` at `version` whose members declare the readmes of `text_for`; `ref_of` is each member's `readme` value.
fn createBody(fx: *Fx, version: []const u8) ![]const u8 {
    const a = fx.life.allocator();
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice("{\"members\":[");
    for (abc, text_for, 0..) |n, text, i| {
        if (i > 0) try out.append(',');
        try out.writer().print(
            "{{\"name\":\"{s}\",\"version\":\"{s}\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"mojo-{s}-{s}-mojo1.0.0_0.conda\",\"sha256\":\"{s}\",\"size\":{d}}}],\"readme\":{s}}}",
            .{ n, version, n, version, try fx.sha(try std.fmt.allocPrint(a, "{s}x", .{n})), n.len + 1, try refJson(fx, text) },
        );
    }
    try out.appendSlice("]}");
    return out.items;
}

/// A commit body for `abc`: each member names its readme by ref, or carries it inline.
fn commitBody(fx: *Fx, refs: bool) ![]const u8 {
    const a = fx.life.allocator();
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice("{\"members\":[");
    for (abc, text_for, 0..) |n, text, i| {
        if (i > 0) try out.append(',');
        try out.writer().print("{{\"name\":\"{s}\",\"manifest_sha256\":\"{s}\",\"readme\":", .{ n, try fx.sha(n) });
        if (refs) try out.appendSlice(try refJson(fx, text)) else try std.json.stringify(text, .{}, out.writer());
        try out.append('}');
    }
    try out.appendSlice("]}");
    return out.items;
}

fn commitPath(fx: *Fx, created: Reply) ![]const u8 {
    return std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/commit", .{idOf(created)});
}

fn readmeOf(created: Reply, member: usize) Value {
    return created.value.object.get("members").?.array.items[member].object.get("readme").?;
}

fn putReadme(fx: *Fx, created: Reply, member: usize, bytes: []const u8) !Reply {
    const id = readmeOf(created, member).object.get("upload_id").?.string;
    return fx.call(.PUT, try std.fmt.allocPrint(fx.life.allocator(), "/_fake/upload/{s}", .{id}), bytes, null);
}

fn putAllReadmes(fx: *Fx, created: Reply) !void {
    for (text_for, 0..) |text, i| try std.testing.expectEqual(@as(u16, 200), (try putReadme(fx, created, i, text)).status);
}

/// Creates the group of `abc` with readme declarations and uploads its files, not its readmes.
fn createWithFiles(fx: *Fx) !Reply {
    const created = try fx.call(.POST, "/api/v1/groups", try createBody(fx, "1.0.0"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    try fx.upload(created, "x");
    return created;
}

fn expectDetail(r: Reply, want_code: []const u8, status: u16, needle: []const u8) !void {
    try expectCode(r, status, want_code);
    if (std.mem.indexOf(u8, r.body, needle) == null) {
        std.debug.print("want {s} in {s}\n", .{ needle, r.body });
        return error.TestUnexpectedResult;
    }
}

fn setSwitch(fx: *Fx, on: bool) !void {
    const r = try fx.call(.POST, "/_fake/readme_objects", if (on) "{\"enabled\":true}" else "{\"enabled\":false}", null);
    try std.testing.expectEqual(@as(u16, 200), r.status);
}

fn toVisible(fx: *Fx, created: Reply) !void {
    _ = try fx.status(idOf(created));
    _ = try fx.status(idOf(created));
    try std.testing.expectEqualStrings("visible", try fx.status(idOf(created)));
}

fn getBody(fx: *Fx, path: []const u8) ![]const u8 {
    const r = try fx.call(.GET, path, "", null);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    return r.body;
}

test "health lists group_readme_objects, and stops listing it when the control turns it off" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const on = try fx.call(.GET, "/api/v1/health", "", null);
    const features = on.value.object.get("features").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), features.len);
    try std.testing.expectEqualStrings("group_readme_objects", features[0].string);

    try setSwitch(&fx, false);
    const off = try fx.call(.GET, "/api/v1/health", "", null);
    try std.testing.expectEqual(@as(u16, 200), off.status);
    try std.testing.expect(off.value.object.get("features") == null);
    try std.testing.expectEqualStrings("ok", off.value.object.get("status").?.string);

    try setSwitch(&fx, true);
    try std.testing.expect((try fx.call(.GET, "/api/v1/health", "", null)).value.object.get("features") != null);
    try expectCode(try fx.call(.POST, "/_fake/readme_objects", "{\"enabled\":1}", null), 400, "invalid_request");
}

test "a create answers where to PUT a declared readme, and says uploaded once the bytes are stored" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try createBody(&fx, "1.0.0"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    for (text_for, 0..) |text, i| {
        const r = readmeOf(created, i).object;
        try std.testing.expectEqualStrings(try fx.sha(text), r.get("sha256").?.string);
        try std.testing.expectEqual(@as(i64, @intCast(text.len)), r.get("size").?.integer);
        try std.testing.expect(!r.get("uploaded").?.bool);
        try std.testing.expect(std.mem.startsWith(u8, r.get("put_url").?.string, "http://fake.test/_fake/upload/"));
        try std.testing.expect(std.mem.endsWith(u8, r.get("put_url").?.string, r.get("upload_id").?.string));
        try std.testing.expect(r.get("expires_at") != null);
        const headers = r.get("put_headers").?.object;
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(fx.life.allocator(), "{d}", .{text.len}), headers.get("content-length").?.string);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
        var b64: [44]u8 = undefined;
        try std.testing.expectEqualStrings(std.base64.standard.Encoder.encode(&b64, &digest), headers.get("x-amz-checksum-sha256").?.string);
    }
    try std.testing.expectEqual(@as(u16, 200), (try putReadme(&fx, created, 0, text_for[0])).status);
    const again = try fx.call(.POST, "/api/v1/groups", try createBody(&fx, "1.0.0"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), again.status);
    try std.testing.expect(readmeOf(again, 0).object.get("uploaded").?.bool);
    try std.testing.expect(readmeOf(again, 0).object.get("put_url") == null);
    try std.testing.expect(!readmeOf(again, 1).object.get("uploaded").?.bool);
    // A member that declared nothing is answered no readme.
    const plain = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "2.0.0", "x"), fx.alice_token);
    try std.testing.expect(plain.value.object.get("members").?.array.items[0].object.get("readme") == null);
}

test "bytes that are not the declared readme are refused by the upload route, as a file's are" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try createBody(&fx, "1.0.0"), fx.alice_token);
    try expectCode(try putReadme(&fx, created, 0, "short"), 400, "invalid_request");
    const same_length = try fx.life.allocator().dupe(u8, text_for[0]);
    same_length[3] = 'Z';
    try expectCode(try putReadme(&fx, created, 0, same_length), 400, "invalid_request");
    const again = try fx.call(.POST, "/api/v1/groups", try createBody(&fx, "1.0.0"), fx.alice_token);
    try std.testing.expect(!readmeOf(again, 0).object.get("uploaded").?.bool);
}

test "a commit naming a readme that was not uploaded is upload_invalid naming the member, and the group stays open" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try createWithFiles(&fx);
    const path = try commitPath(&fx, created);
    try expectDetail(try fx.call(.POST, path, try commitBody(&fx, true), fx.alice_token), "upload_invalid", 400, "the readme of 'pkg_a' (sha256 ");
    try std.testing.expectEqualStrings("open", try fx.status(idOf(created)));
    // Two of three stored: the third is the one named.
    try std.testing.expectEqual(@as(u16, 200), (try putReadme(&fx, created, 0, text_for[0])).status);
    try std.testing.expectEqual(@as(u16, 200), (try putReadme(&fx, created, 1, text_for[1])).status);
    try expectDetail(try fx.call(.POST, path, try commitBody(&fx, true), fx.alice_token), "upload_invalid", 400, "the readme of 'pkg_c' (sha256 ");
    try std.testing.expectEqualStrings("open", try fx.status(idOf(created)));
    try std.testing.expectEqual(@as(u16, 200), (try putReadme(&fx, created, 2, text_for[2])).status);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, try commitBody(&fx, true), fx.alice_token)).status);
}

test "a commit ref with a size or a digest other than the stored object is refused naming the member" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try createWithFiles(&fx);
    try putAllReadmes(&fx, created);
    const path = try commitPath(&fx, created);
    const a = fx.life.allocator();
    const good = try commitBody(&fx, true);
    // pkg_b's size is one more than the stored object's.
    const wrong_size = try std.mem.replaceOwned(u8, a, good, try refJson(&fx, text_for[1]), try std.fmt.allocPrint(a, "{{\"sha256\":\"{s}\",\"size\":{d}}}", .{ try fx.sha(text_for[1]), text_for[1].len + 1 }));
    try expectDetail(try fx.call(.POST, path, wrong_size, fx.alice_token), "upload_invalid", 400, "the readme of 'pkg_b' in storage is not the one named (sha256 ");
    // pkg_a's digest is of other text: no object by that digest was uploaded.
    const wrong_sha = try std.mem.replaceOwned(u8, a, good, try fx.sha(text_for[0]), try fx.sha("other"));
    try expectDetail(try fx.call(.POST, path, wrong_sha, fx.alice_token), "upload_invalid", 400, "the readme of 'pkg_a' (sha256 ");
    try std.testing.expectEqualStrings("open", try fx.status(idOf(created)));
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, good, fx.alice_token)).status);
}

test "a readme object that is not UTF-8 text is refused naming the member" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const bad = "# pkg_a \xFF\xFE not text\n";
    const a = fx.life.allocator();
    const body = try std.mem.replaceOwned(u8, a, try createBody(&fx, "1.0.0"), try refJson(&fx, text_for[0]), try refJson(&fx, bad));
    const created = try fx.call(.POST, "/api/v1/groups", body, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    try fx.upload(created, "x");
    try std.testing.expectEqual(@as(u16, 200), (try putReadme(&fx, created, 0, bad)).status);
    try std.testing.expectEqual(@as(u16, 200), (try putReadme(&fx, created, 1, text_for[1])).status);
    try std.testing.expectEqual(@as(u16, 200), (try putReadme(&fx, created, 2, text_for[2])).status);
    const commit = try std.mem.replaceOwned(u8, a, try commitBody(&fx, true), try refJson(&fx, text_for[0]), try refJson(&fx, bad));
    const path = try commitPath(&fx, created);
    try expectDetail(try fx.call(.POST, path, commit, fx.alice_token), "invalid_request", 400, "the readme of 'pkg_a' is not UTF-8 text");
    try std.testing.expectEqualStrings("open", try fx.status(idOf(created)));
}

test "a readme that is not a well-formed ref is refused at create and at commit, naming the member" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = fx.life.allocator();
    const sha = try fx.sha("x");
    const bad_refs = [_][]const u8{
        "3",
        "null",
        "[]",
        "{}",
        "{\"sha256\":\"abc\",\"size\":5}",
        try std.fmt.allocPrint(a, "{{\"sha256\":\"{s}\"}}", .{sha}),
        try std.fmt.allocPrint(a, "{{\"sha256\":\"{s}\",\"size\":\"5\"}}", .{sha}),
        try std.fmt.allocPrint(a, "{{\"sha256\":\"{s}\",\"size\":0}}", .{sha}),
        try std.fmt.allocPrint(a, "{{\"sha256\":\"{s}\",\"size\":65537}}", .{sha}),
        try std.fmt.allocPrint(a, "{{\"sha256\":\"{s}\",\"size\":5}}", .{try std.ascii.allocUpperString(a, sha)}),
    };
    const created = try createWithFiles(&fx);
    const path = try commitPath(&fx, created);
    try putAllReadmes(&fx, created);
    for (bad_refs) |bad| {
        const make = try std.mem.replaceOwned(u8, a, try createBody(&fx, "1.0.0"), try refJson(&fx, text_for[0]), bad);
        const refused = try fx.call(.POST, "/api/v1/groups", make, fx.alice_token);
        try expectDetail(refused, "invalid_request", 400, "'readme' of 'pkg_a' is {\\\"sha256\\\", \\\"size\\\"} of a readme of 1 to 65536 bytes");
        const commit = try std.mem.replaceOwned(u8, a, try commitBody(&fx, true), try refJson(&fx, text_for[0]), bad);
        const rejected = try fx.call(.POST, path, commit, fx.alice_token);
        try expectDetail(rejected, "invalid_request", 400, "'readme' of 'pkg_a' is a string or {\\\"sha256\\\", \\\"size\\\"} of a readme of 1 to 65536 bytes");
    }
    try std.testing.expectEqualStrings("open", try fx.status(idOf(created)));
    // A description that is not a string keeps its own refusal.
    const description = try std.mem.replaceOwned(u8, a, try commitBody(&fx, true), "\"readme\":", "\"description\":3,\"readme\":");
    try expectDetail(try fx.call(.POST, path, description, fx.alice_token), "invalid_request", 400, "'description' of 'pkg_a' must be a string");
    // Nor is a ref's readme taken for an inline text of the wrong size.
    try expectDetail(try fx.call(.POST, path, try std.mem.replaceOwned(u8, a, try commitBody(&fx, false), "# pkg_a\\nthe first\\n", ""), fx.alice_token), "invalid_request", 400, "'readme' of 'pkg_a' is empty or too long");
}

test "an inline commit is still accepted, also for a group created with readme declarations" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try createWithFiles(&fx);
    const path = try commitPath(&fx, created);
    // No readme object was uploaded: the inline form does not need one.
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, try commitBody(&fx, false), fx.alice_token)).status);
    try toVisible(&fx, created);
    const shown = try fx.call(.GET, "/api/v1/packages/pkg_c/1.0.0", "", null);
    try std.testing.expectEqualStrings(text_for[2], shown.value.object.get("readme").?.string);
}

test "after visible, getVersion and getPackage serve the readme, and a package without one serves none" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try createWithFiles(&fx);
    try putAllReadmes(&fx, created);
    // A version published before has no readme to serve.
    const first = try fx.call(.POST, "/api/v1/groups", try fx.request(&.{"pkg_a"}, "0.5.0", "x"), fx.alice_token);
    try fx.upload(first, "x");
    const first_path = try commitPath(&fx, first);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, first_path, try fx.commitBody(&.{"pkg_a"}), fx.alice_token)).status);
    try toVisible(&fx, first);
    const old = try fx.call(.GET, "/api/v1/packages/pkg_a/0.5.0", "", null);
    try std.testing.expect(old.value.object.get("readme") == null);
    try std.testing.expect((try fx.call(.GET, "/api/v1/packages/pkg_a", "", null)).value.object.get("readme") == null);

    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try commitPath(&fx, created), try commitBody(&fx, true), fx.alice_token)).status);
    // Not visible yet: nothing is served.
    try std.testing.expectEqual(@as(u16, 404), (try fx.call(.GET, "/api/v1/packages/pkg_c/1.0.0", "", null)).status);
    try toVisible(&fx, created);
    for (abc, text_for) |n, text| {
        const v = try fx.call(.GET, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/packages/{s}/1.0.0", .{n}), "", null);
        try std.testing.expectEqualStrings(text, v.value.object.get("readme").?.string);
        try std.testing.expect(v.value.object.get("readme_html") != null);
        const p = try fx.call(.GET, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/packages/{s}", .{n}), "", null);
        try std.testing.expectEqualStrings(text, p.value.object.get("readme").?.string);
    }
}

/// Publishes `abc` at 1.0.0 in a fresh fixture in the form `refs` says, with every time the answers and files show pinned.
fn publishedIn(fx: *Fx, refs: bool) !void {
    try fx.setup();
    const created = try createWithFiles(fx);
    try putAllReadmes(fx, created);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try commitPath(fx, created), try commitBody(fx, refs), fx.alice_token)).status);
    try toVisible(fx, created);
    for (fx.state.packages.items) |p| {
        p.created_at = 1000;
        p.updated_at = 1000;
        for (p.versions.items) |v| v.published_at = 1000;
    }
    try files.rewrite(fx.life.allocator(), &fx.state);
}

test "the two forms give byte-identical getVersion and getPackage bodies and channel and index files" {
    var refs: Fx = undefined;
    try publishedIn(&refs, true);
    defer refs.deinit();
    var inline_form: Fx = undefined;
    try publishedIn(&inline_form, false);
    defer inline_form.deinit();
    const paths = [_][]const u8{
        "/api/v1/packages/pkg_a/1.0.0",
        "/api/v1/packages/pkg_b/1.0.0",
        "/api/v1/packages/pkg_c/1.0.0",
        "/api/v1/packages/pkg_a",
        "/api/v1/packages/pkg_b",
        "/api/v1/packages/pkg_c",
        "/api/v1/packages/pkg_c/versions",
        "/index/pk/g_/pkg_a",
        "/index/pk/g_/pkg_b",
        "/index/pk/g_/pkg_c",
        "/channel/noarch/repodata.json",
        "/channel/noarch/current_repodata.json",
        "/index/config.json",
    };
    for (paths) |path| {
        const want = try getBody(&inline_form, path);
        try std.testing.expectEqualStrings(want, try getBody(&refs, path));
    }
}

test "a repeat of the object-form commit is a repeat even after the objects are gone, and the other form is another request" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try createWithFiles(&fx);
    try putAllReadmes(&fx, created);
    const path = try commitPath(&fx, created);
    const refs = try commitBody(&fx, true);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, refs, fx.alice_token)).status);
    for (fx.state.uploads.items) |u| {
        if (std.mem.eql(u8, u.filename, "README.md")) try fx.tmp.dir.deleteFile(u.path.?);
    }
    const repeat = try fx.call(.POST, path, refs, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 202), repeat.status);
    try std.testing.expectEqualStrings("validating", repeat.value.object.get("status").?.string);
    try expectCode(try fx.call(.POST, path, try commitBody(&fx, false), fx.alice_token), 409, "group_commit_refused");
    try toVisible(&fx, created);
    const done = try fx.call(.POST, path, refs, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), done.status);
    try expectCode(try fx.call(.POST, path, try commitBody(&fx, false), fx.alice_token), 409, "group_commit_refused");
}

test "switched off, the fake ignores declared readmes and refuses the object form with the old message" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    try setSwitch(&fx, false);
    // A declaration, even a malformed one, is ignored and not answered.
    const a = fx.life.allocator();
    const body = try std.mem.replaceOwned(u8, a, try createBody(&fx, "1.0.0"), try refJson(&fx, text_for[1]), "7");
    const created = try fx.call(.POST, "/api/v1/groups", body, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    for (created.value.object.get("members").?.array.items) |m| try std.testing.expect(m.object.get("readme") == null);
    try fx.upload(created, "x");
    const path = try commitPath(&fx, created);
    try expectDetail(try fx.call(.POST, path, try commitBody(&fx, true), fx.alice_token), "invalid_request", 400, "'readme' of 'pkg_a' must be a string");
    try expectDetail(try fx.call(.POST, path, "{\"members\":[{\"name\":\"pkg_a\",\"readme\":3}]}", fx.alice_token), "invalid_request", 400, "'readme' of 'pkg_a' must be a string");
    try std.testing.expectEqualStrings("open", try fx.status(idOf(created)));
    // The inline form goes through, and the text is served.
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, try commitBody(&fx, false), fx.alice_token)).status);
    try toVisible(&fx, created);
    const shown = try fx.call(.GET, "/api/v1/packages/pkg_a/1.0.0", "", null);
    try std.testing.expectEqualStrings(text_for[0], shown.value.object.get("readme").?.string);
}

test "switched off after objects were uploaded, they stay in storage" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try createWithFiles(&fx);
    try putAllReadmes(&fx, created);
    try setSwitch(&fx, false);
    var stored: usize = 0;
    for (fx.state.uploads.items) |u| {
        if (std.mem.eql(u8, u.filename, "README.md") and u.path != null) stored += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), stored);
    try setSwitch(&fx, true);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try commitPath(&fx, created), try commitBody(&fx, true), fx.alice_token)).status);
}

test "110 members with 64 KiB readmes commit through refs with a body under 64 KiB" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = fx.life.allocator();
    const count = 110;
    const size = 65536;
    var names: [count][]const u8 = undefined;
    var token_names: [count][]const u8 = undefined;
    var texts: [count][]const u8 = undefined;
    const s = &fx.state;
    for (0..count) |i| {
        names[i] = try std.fmt.allocPrint(a, "big_{d:0>3}", .{i});
        token_names[i] = names[i];
        const buf = try a.alloc(u8, size);
        @memset(buf, 'r');
        _ = try std.fmt.bufPrint(buf, "# {s}\n", .{names[i]});
        texts[i] = buf;
        const p = try s.addPackage(.{ .name = names[i], .created_at = s.now(), .updated_at = s.now(), .claim_expires_at = s.now() + st.claim_secs });
        try p.owners.append(a, fx.alice);
    }
    const token = (try s.addToken(.{ .id = "t3", .secret = "big-secret", .kind = .api, .user = fx.alice, .scopes = &.{.publish}, .packages = &token_names, .created_at = s.now(), .expires_at = s.now() + st.day })).secret;

    var create = std.ArrayList(u8).init(a);
    var commit = std.ArrayList(u8).init(a);
    try create.appendSlice("{\"members\":[");
    try commit.appendSlice("{\"members\":[");
    for (names, texts, 0..) |n, text, i| {
        if (i > 0) {
            try create.append(',');
            try commit.append(',');
        }
        try create.writer().print(
            "{{\"name\":\"{s}\",\"version\":\"1.0.0\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"mojo-{s}-1.0.0-mojo1.0.0_0.conda\",\"sha256\":\"{s}\",\"size\":{d}}}],\"readme\":{s}}}",
            .{ n, n, try fx.sha(n), n.len, try refJson(&fx, text) },
        );
        try commit.writer().print("{{\"name\":\"{s}\",\"manifest_sha256\":\"{s}\",\"readme\":{s}}}", .{ n, try fx.sha(n), try refJson(&fx, text) });
    }
    try create.appendSlice("]}");
    try commit.appendSlice("]}");
    try std.testing.expect(commit.items.len < 64 * 1024);

    const created = try fx.call(.POST, "/api/v1/groups", create.items, token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    for (created.value.object.get("members").?.array.items, texts) |m, text| {
        const f = m.object.get("files").?.array.items[0].object;
        const name = m.object.get("name").?.string;
        const put_file = try fx.call(.PUT, try std.fmt.allocPrint(a, "/_fake/upload/{s}", .{f.get("upload_id").?.string}), name, null);
        try std.testing.expectEqual(@as(u16, 200), put_file.status);
        const r = m.object.get("readme").?.object;
        const put = try fx.call(.PUT, try std.fmt.allocPrint(a, "/_fake/upload/{s}", .{r.get("upload_id").?.string}), text, null);
        try std.testing.expectEqual(@as(u16, 200), put.status);
    }
    const path = try commitPath(&fx, created);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, commit.items, token)).status);
    for (0..3) |_| _ = try fx.call(.GET, try std.fmt.allocPrint(a, "/api/v1/groups/{s}", .{idOf(created)}), "", token);
    const last = try fx.call(.GET, "/api/v1/packages/big_109/1.0.0", "", null);
    try std.testing.expectEqualStrings(texts[109], last.value.object.get("readme").?.string);
}
