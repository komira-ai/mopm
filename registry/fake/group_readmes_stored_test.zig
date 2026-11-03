//! Unit tests of what a readme is as stored and as served (group_readmes.zig): the object as it is now in storage, the request
//! hash of the two forms, the readmes a package shows across versions, and the bodies of the released client. The fixture and
//! the helpers are those of group_readmes_test.zig.

const std = @import("std");
const t = @import("groups_test.zig");
const rt = @import("group_readmes_test.zig");
const Fx = t.Fx;
const Reply = t.Reply;
const abc = t.abc;
const idOf = t.idOf;
const expectCode = t.expectCode;
const expectDetail = rt.expectDetail;
const text_for = rt.text_for;

const only_a: []const []const u8 = &.{"pkg_a"};

/// A create request for `names` at `version`; a member whose entry in `texts` is not null declares it as its readme. Each file is
/// named for `file_pkg` when that is given.
fn createFor(fx: *Fx, names: []const []const u8, version: []const u8, texts: []const ?[]const u8, file_pkg: ?[]const u8, token: []const u8) !Reply {
    const a = fx.life.allocator();
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice("{\"members\":[");
    for (names, texts, 0..) |n, text, i| {
        if (i > 0) try out.append(',');
        try out.writer().print(
            "{{\"name\":\"{s}\",\"version\":\"{s}\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"mojo-{s}-{s}-mojo1.0.0_0.conda\",\"sha256\":\"{s}\",\"size\":{d}}}]",
            .{ n, version, file_pkg orelse n, version, try fx.sha(try std.fmt.allocPrint(a, "{s}x", .{n})), n.len + 1 },
        );
        if (text) |x| try out.writer().print(",\"readme\":{s}", .{try rt.refJson(fx, x)});
        try out.append('}');
    }
    try out.appendSlice("]}");
    return fx.call(.POST, "/api/v1/groups", out.items, token);
}

/// A commit body for `names`: a member's readme is a ref or the text, or absent when its entry in `texts` is null.
fn commitFor(fx: *Fx, names: []const []const u8, texts: []const ?[]const u8, refs: bool) ![]const u8 {
    const a = fx.life.allocator();
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice("{\"members\":[");
    for (names, texts, 0..) |n, text, i| {
        if (i > 0) try out.append(',');
        try out.writer().print("{{\"name\":\"{s}\",\"manifest_sha256\":\"{s}\"", .{ n, try fx.sha(n) });
        if (text) |x| {
            try out.appendSlice(",\"readme\":");
            if (refs) try out.appendSlice(try rt.refJson(fx, x)) else try std.json.stringify(x, .{}, out.writer());
        }
        try out.append('}');
    }
    try out.appendSlice("]}");
    return out.items;
}

/// Polls the group until it stops moving and returns its status.
fn settle(fx: *Fx, id: []const u8) ![]const u8 {
    var last: []const u8 = "";
    for (0..3) |_| last = try fx.status(id);
    return last;
}

/// Publishes pkg_a at `version` alone, with `text` as its readme in the form `refs` says, and returns the status the group ends in.
fn publishA(fx: *Fx, version: []const u8, text: ?[]const u8, refs: bool, file_pkg: ?[]const u8) ![]const u8 {
    const created = try createFor(fx, only_a, version, &.{if (refs) text else null}, file_pkg, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    try fx.upload(created, "x");
    if (text != null and refs) try std.testing.expectEqual(@as(u16, 200), (try rt.putReadme(fx, created, 0, text.?)).status);
    const commit = try fx.call(.POST, try rt.commitPath(fx, created), try commitFor(fx, only_a, &.{text}, refs), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 202), commit.status);
    return settle(fx, idOf(created));
}

fn expectReadme(want: ?[]const u8, r: Reply) !void {
    try std.testing.expectEqual(@as(u16, 200), r.status);
    const got = r.value.object.get("readme");
    if (want) |w| {
        try std.testing.expectEqualStrings(w, got.?.string);
    } else {
        try std.testing.expect(got == null);
    }
}

fn versionReadme(fx: *Fx, name: []const u8, version: []const u8, want: ?[]const u8) !void {
    try expectReadme(want, try fx.call(.GET, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/packages/{s}/{s}", .{ name, version }), "", null));
}

fn packageReadme(fx: *Fx, name: []const u8, want: ?[]const u8) !void {
    try expectReadme(want, try fx.call(.GET, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/packages/{s}", .{name}), "", null));
}

// ---------------------------------------------------------------------------
// the request hash
// ---------------------------------------------------------------------------

fn markerOf(fx: *Fx, text: []const u8) ![]const u8 {
    const raw = try std.fmt.allocPrint(fx.life.allocator(), "\x00ref {s} {d}", .{ try fx.sha(text), text.len });
    var out = std.ArrayList(u8).init(fx.life.allocator());
    try std.json.stringify(raw, .{}, out.writer());
    return out.items;
}

test "an inline readme spelled like the old reference bytes is another request than the reference" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = fx.life.allocator();
    const created = try rt.createWithFiles(&fx);
    try rt.putAllReadmes(&fx, created);
    const path = try rt.commitPath(&fx, created);
    const refs = try rt.commitBody(&fx, true);
    const spelled = try std.mem.replaceOwned(u8, a, refs, try rt.refJson(&fx, text_for[0]), try markerOf(&fx, text_for[0]));
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, refs, fx.alice_token)).status);
    try expectCode(try fx.call(.POST, path, spelled, fx.alice_token), 409, "group_commit_refused");
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, refs, fx.alice_token)).status);

    // The other way round: the spelled text first, then the reference.
    var second: Fx = undefined;
    try second.setup();
    defer second.deinit();
    const made = try rt.createWithFiles(&second);
    try rt.putAllReadmes(&second, made);
    const second_path = try rt.commitPath(&second, made);
    const second_spelled = try std.mem.replaceOwned(u8, a, try rt.commitBody(&second, true), try rt.refJson(&second, text_for[0]), try markerOf(&second, text_for[0]));
    try std.testing.expectEqual(@as(u16, 202), (try second.call(.POST, second_path, second_spelled, second.alice_token)).status);
    try expectCode(try second.call(.POST, second_path, try rt.commitBody(&second, true), second.alice_token), 409, "group_commit_refused");
    try std.testing.expectEqual(@as(u16, 202), (try second.call(.POST, second_path, second_spelled, second.alice_token)).status);
}

test "a commit of inline texts only is named by the hash it has always had" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    try fx.upload(created, "x");
    const texts = [_]?[]const u8{ "alpha", "beta", null };
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try rt.commitPath(&fx, created), try commitFor(&fx, abc, &texts, false), fx.alice_token)).status);
    // One line per member, `name:manifest:description NUL licence NUL readme NUL:source`, the lines sorted and each ended by a
    // newline, after the empty line the last newline leaves.
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("\n");
    for (abc, texts) |n, text| {
        h.update(try std.fmt.allocPrint(fx.life.allocator(), "{s}:{s}:\x00\x00{s}\x00:\n", .{ n, try fx.sha(n), text orelse "" }));
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const want = try std.fmt.allocPrint(fx.life.allocator(), "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
    try std.testing.expectEqualStrings(want, fx.state.groups.items[0].commit_hash);
}

// ---------------------------------------------------------------------------
// the empty readme
// ---------------------------------------------------------------------------

test "an empty inline readme is taken, recorded and served as the empty string, and is not the same request as none" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    try std.testing.expectEqualStrings("visible", try publishA(&fx, "1.0.0", "", false, null));
    try versionReadme(&fx, "pkg_a", "1.0.0", "");
    try packageReadme(&fx, "pkg_a", "");

    const with_empty = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "2.0.0", "x"), fx.alice_token);
    try fx.upload(with_empty, "x");
    const path = try rt.commitPath(&fx, with_empty);
    const empty_body = try commitFor(&fx, abc, &.{ "", null, null }, false);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, empty_body, fx.alice_token)).status);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, empty_body, fx.alice_token)).status);
    try expectCode(try fx.call(.POST, path, try commitFor(&fx, abc, &.{ null, null, null }, false), fx.alice_token), 409, "group_commit_refused");

    const without = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "3.0.0", "x"), fx.alice_token);
    try fx.upload(without, "x");
    const other = try rt.commitPath(&fx, without);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, other, try commitFor(&fx, abc, &.{ null, null, null }, false), fx.alice_token)).status);
    try expectCode(try fx.call(.POST, other, empty_body, fx.alice_token), 409, "group_commit_refused");
}

test "an empty description or licence is still refused" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(only_a, "1.0.0", "x"), fx.alice_token);
    const path = try rt.commitPath(&fx, created);
    const a = fx.life.allocator();
    for ([_][]const u8{ "description", "license" }) |key| {
        const body = try std.fmt.allocPrint(a, "{{\"members\":[{{\"name\":\"pkg_a\",\"{s}\":\"\"}}]}}", .{key});
        try expectDetail(try fx.call(.POST, path, body, fx.alice_token), "invalid_request", 400, try std.fmt.allocPrint(a, "'{s}' of 'pkg_a' is empty or too long", .{key}));
    }
}

// ---------------------------------------------------------------------------
// a declaration again
// ---------------------------------------------------------------------------

test "a create that declared the right digest with a wrong size is put right by the create that has the right size" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = fx.life.allocator();
    const right = try rt.createBody(&fx, "1.0.0");
    const wrong = try std.mem.replaceOwned(u8, a, right, try rt.refJson(&fx, text_for[0]), try std.fmt.allocPrint(a, "{{\"sha256\":\"{s}\",\"size\":{d}}}", .{ try fx.sha(text_for[0]), text_for[0].len + 1 }));
    const first = try fx.call(.POST, "/api/v1/groups", wrong, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), first.status);
    try std.testing.expectEqual(@as(i64, @intCast(text_for[0].len + 1)), rt.readmeOf(first, 0).object.get("size").?.integer);
    try expectCode(try rt.putReadme(&fx, first, 0, text_for[0]), 400, "invalid_request");

    const second = try fx.call(.POST, "/api/v1/groups", right, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), second.status);
    const answer = rt.readmeOf(second, 0).object;
    try std.testing.expectEqual(@as(i64, @intCast(text_for[0].len)), answer.get("size").?.integer);
    try std.testing.expect(!answer.get("uploaded").?.bool);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{text_for[0].len}), answer.get("put_headers").?.object.get("content-length").?.string);
    try std.testing.expectEqualStrings(idOf(first), idOf(second));
    try std.testing.expectEqual(@as(u16, 200), (try rt.putReadme(&fx, second, 0, text_for[0])).status);
    try std.testing.expectEqual(@as(u16, 200), (try rt.putReadme(&fx, second, 1, text_for[1])).status);
    try std.testing.expectEqual(@as(u16, 200), (try rt.putReadme(&fx, second, 2, text_for[2])).status);
    try fx.upload(second, "x");
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try rt.commitPath(&fx, second), try rt.commitBody(&fx, true), fx.alice_token)).status);
    try rt.toVisible(&fx, second);
    try versionReadme(&fx, "pkg_a", "1.0.0", text_for[0]);
}

// ---------------------------------------------------------------------------
// the object as it is stored now
// ---------------------------------------------------------------------------

fn objectPath(fx: *Fx, created: Reply, member: usize) []const u8 {
    const id = rt.readmeOf(created, member).object.get("upload_id").?.string;
    for (fx.state.uploads.items) |u| {
        if (std.mem.eql(u8, u.id, id)) return u.path.?;
    }
    unreachable;
}

/// After `damage` has changed pkg_a's stored readme: the commit names the member and leaves the group open, the create answers a
/// URL for it (and none for the others), and a PUT of the right bytes makes the commit go through.
fn expectDamageRefused(damage: *const fn (fx: *Fx, path: []const u8) anyerror!void, needle: []const u8, member: usize, name: []const u8) !void {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try rt.createWithFiles(&fx);
    try rt.putAllReadmes(&fx, created);
    try damage(&fx, objectPath(&fx, created, member));
    const path = try rt.commitPath(&fx, created);
    const refused = try fx.call(.POST, path, try rt.commitBody(&fx, true), fx.alice_token);
    try expectDetail(refused, "upload_invalid", 400, try std.fmt.allocPrint(fx.life.allocator(), "the readme of '{s}' {s}", .{ name, needle }));
    try std.testing.expectEqualStrings("open", try fx.status(idOf(created)));

    const again = try fx.call(.POST, "/api/v1/groups", try rt.createBody(&fx, "1.0.0"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), again.status);
    for (0..3) |i| {
        const r = rt.readmeOf(again, i).object;
        try std.testing.expectEqual(i != member, r.get("uploaded").?.bool);
        try std.testing.expectEqual(i == member, r.get("put_url") != null);
    }
    try std.testing.expectEqual(@as(u16, 200), (try rt.putReadme(&fx, again, member, text_for[member])).status);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, try rt.commitBody(&fx, true), fx.alice_token)).status);
}

fn remove(fx: *Fx, path: []const u8) anyerror!void {
    try fx.tmp.dir.deleteFile(path);
}

fn sameLength(fx: *Fx, path: []const u8) anyerror!void {
    const bytes = try fx.life.allocator().dupe(u8, text_for[1]);
    bytes[3] = 'Z';
    try fx.tmp.dir.writeFile(path, bytes);
}

fn shorter(fx: *Fx, path: []const u8) anyerror!void {
    try fx.tmp.dir.writeFile(path, text_for[1][0..4]);
}

fn longer(fx: *Fx, path: []const u8) anyerror!void {
    const bytes = try std.mem.concat(fx.life.allocator(), u8, &.{ text_for[1], "more" });
    try fx.tmp.dir.writeFile(path, bytes);
}

fn emptied(fx: *Fx, path: []const u8) anyerror!void {
    try fx.tmp.dir.writeFile(path, "");
}

test "a readme object deleted after its PUT is not uploaded: upload_invalid naming the member, and a create answers a URL again" {
    try expectDamageRefused(&remove, "(sha256 ", 1, "pkg_b");
}

test "a readme object that is not the named bytes any more is refused as not the one named, and a create answers a URL again" {
    const needle = "in storage is not the one named (sha256 ";
    try expectDamageRefused(&sameLength, needle, 1, "pkg_b");
    try expectDamageRefused(&shorter, needle, 1, "pkg_b");
    try expectDamageRefused(&longer, needle, 1, "pkg_b");
    try expectDamageRefused(&emptied, needle, 1, "pkg_b");
}

test "a readme object deleted after its PUT says was not uploaded" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const created = try rt.createWithFiles(&fx);
    try rt.putAllReadmes(&fx, created);
    try fx.tmp.dir.deleteFile(objectPath(&fx, created, 2));
    const refused = try fx.call(.POST, try rt.commitPath(&fx, created), try rt.commitBody(&fx, true), fx.alice_token);
    try expectDetail(refused, "upload_invalid", 400, "the readme of 'pkg_c' (sha256 ");
    try expectDetail(refused, "upload_invalid", 400, "was not uploaded");
}

// ---------------------------------------------------------------------------
// the same bytes elsewhere
// ---------------------------------------------------------------------------

test "two members with identical readme bytes each need their own object" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const same = "# the same\n";
    const names: []const []const u8 = &.{ "pkg_a", "pkg_b" };
    const texts = [_]?[]const u8{ same, same };
    const created = try createFor(&fx, names, "1.0.0", &texts, null, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    try fx.upload(created, "x");
    try std.testing.expect(!std.mem.eql(u8, rt.readmeOf(created, 0).object.get("upload_id").?.string, rt.readmeOf(created, 1).object.get("upload_id").?.string));
    try std.testing.expectEqual(@as(u16, 200), (try rt.putReadme(&fx, created, 0, same)).status);

    // pkg_b names the digest pkg_a's object has, and gets no credit for it.
    const path = try rt.commitPath(&fx, created);
    const body = try commitFor(&fx, names, &texts, true);
    try expectDetail(try fx.call(.POST, path, body, fx.alice_token), "upload_invalid", 400, "the readme of 'pkg_b' (sha256 ");
    const again = try createFor(&fx, names, "1.0.0", &texts, null, fx.alice_token);
    try std.testing.expect(rt.readmeOf(again, 0).object.get("uploaded").?.bool);
    try std.testing.expect(!rt.readmeOf(again, 1).object.get("uploaded").?.bool);
    try std.testing.expectEqual(@as(u16, 200), (try rt.putReadme(&fx, created, 1, same)).status);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, path, body, fx.alice_token)).status);
}

test "identical readme bytes in another group, also another user's, are not uploaded for this one" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const same = "# the same\n";
    const texts = [_]?[]const u8{same};
    const first = try createFor(&fx, only_a, "1.0.0", &texts, null, fx.alice_token);
    try fx.upload(first, "x");
    try std.testing.expectEqual(@as(u16, 200), (try rt.putReadme(&fx, first, 0, same)).status);
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try rt.commitPath(&fx, first), try commitFor(&fx, only_a, &texts, true), fx.alice_token)).status);

    const tokens = [_][]const u8{ fx.alice_token, fx.bob_token };
    const versions = [_][]const u8{ "2.0.0", "3.0.0" };
    for (tokens, versions) |token, version| {
        const next = try createFor(&fx, only_a, version, &texts, null, token);
        try std.testing.expectEqual(@as(u16, 201), next.status);
        try fx.upload(next, "x");
        const r = rt.readmeOf(next, 0).object;
        try std.testing.expect(!r.get("uploaded").?.bool);
        try std.testing.expect(r.get("put_url") != null);
        const refused = try fx.call(.POST, try rt.commitPath(&fx, next), try commitFor(&fx, only_a, &texts, true), token);
        try expectDetail(refused, "upload_invalid", 400, "the readme of 'pkg_a' (sha256 ");
    }
}

// ---------------------------------------------------------------------------
// the readme of a package
// ---------------------------------------------------------------------------

fn readmesAcrossVersions(refs: bool) !void {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    try std.testing.expectEqualStrings("visible", try publishA(&fx, "1.0.0", "one", refs, null));
    try packageReadme(&fx, "pkg_a", "one");
    // A later version with another readme replaces it on the package, and the older version keeps its own.
    try std.testing.expectEqualStrings("visible", try publishA(&fx, "2.0.0", "two", refs, null));
    try packageReadme(&fx, "pkg_a", "two");
    try versionReadme(&fx, "pkg_a", "1.0.0", "one");
    try versionReadme(&fx, "pkg_a", "2.0.0", "two");
    // The latest yanked: the package shows the readme of the newest version that is not.
    const yank = try fx.call(.PUT, "/api/v1/packages/pkg_a/2.0.0/yank", "{\"yanked\":true,\"reason\":\"bad\"}", fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), yank.status);
    try packageReadme(&fx, "pkg_a", "one");
    try versionReadme(&fx, "pkg_a", "2.0.0", "two");
    // A later version with none: the package shows none.
    try std.testing.expectEqualStrings("visible", try publishA(&fx, "3.0.0", null, refs, null));
    try packageReadme(&fx, "pkg_a", null);
    try versionReadme(&fx, "pkg_a", "3.0.0", null);
    try versionReadme(&fx, "pkg_a", "1.0.0", "one");
    // A later group that is rejected publishes nothing, readme included.
    try std.testing.expectEqualStrings("rejected", try publishA(&fx, "4.0.0", "four", refs, "pkg_other"));
    try packageReadme(&fx, "pkg_a", null);
    try std.testing.expectEqual(@as(u16, 404), (try fx.call(.GET, "/api/v1/packages/pkg_a/4.0.0", "", null)).status);
    // Unyanked, the version is the latest again.
    const unyank = try fx.call(.PUT, "/api/v1/packages/pkg_a/2.0.0/yank", "{\"yanked\":false}", fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), unyank.status);
    try packageReadme(&fx, "pkg_a", null);
    try versionReadme(&fx, "pkg_a", "2.0.0", "two");
}

test "the readme of a package follows its latest version through later versions, a yank and a rejected group, with readme objects" {
    try readmesAcrossVersions(true);
}

test "the readme of a package follows its latest version through later versions, a yank and a rejected group, with inline texts" {
    try readmesAcrossVersions(false);
}

// ---------------------------------------------------------------------------
// the released client
// ---------------------------------------------------------------------------

test "the create and commit bodies the released client sends, readmes inline, publish and serve them" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    // The create body of src/cli/group_publish.zig createBody at d0b9020 has no readme: the text goes in the commit.
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    for (created.value.object.get("members").?.array.items) |m| try std.testing.expect(m.object.get("readme") == null);
    try fx.upload(created, "x");
    // The commit body of src/cli/group_plan.zig commitBody at d0b9020: strings as std.json.encodeJsonString writes them, a
    // member without a readme has no key, an empty readme is "".
    const body = try std.fmt.allocPrint(
        fx.life.allocator(),
        "{{\"members\":[{{\"name\":\"pkg_a\",\"manifest_sha256\":\"{s}\",\"readme\":\"# pkg_a\\nthe \\\"first\\\" \\\\ caf\xC3\xA9\\t\\u0001\\n\"}},{{\"name\":\"pkg_b\",\"manifest_sha256\":\"{s}\"}},{{\"name\":\"pkg_c\",\"manifest_sha256\":\"{s}\",\"readme\":\"\"}}]}}",
        .{ try fx.sha("pkg_a"), try fx.sha("pkg_b"), try fx.sha("pkg_c") },
    );
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try rt.commitPath(&fx, created), body, fx.alice_token)).status);
    try rt.toVisible(&fx, created);
    try versionReadme(&fx, "pkg_a", "1.0.0", "# pkg_a\nthe \"first\" \\ caf\xC3\xA9\t\x01\n");
    try versionReadme(&fx, "pkg_b", "1.0.0", null);
    try versionReadme(&fx, "pkg_c", "1.0.0", "");
    try packageReadme(&fx, "pkg_a", "# pkg_a\nthe \"first\" \\ caf\xC3\xA9\t\x01\n");
    try packageReadme(&fx, "pkg_b", null);
    try packageReadme(&fx, "pkg_c", "");
}
