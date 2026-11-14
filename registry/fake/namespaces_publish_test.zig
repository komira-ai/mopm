//! Unit tests of publishing through `/api/v2` (spec/proposed/namespaces.md): a single publish and a group of packages in
//! namespaces, a takedown, and the CI identity exchange of a namespace's publishers; and the files they leave for a client
//! (index version 2, the namespace's channel, `config.json`). Requests go through `api.handle` with the fixture of
//! namespaces_test.zig.

const std = @import("std");
const t = @import("namespaces_test.zig");
const Nx = t.Nx;
const Reply = t.Reply;
const expectStatus = t.expectStatus;
const expectCode = t.expectCode;
const str = t.str;

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// Begins an upload of `bytes` as `filename` for `key` at `version`, PUTs the bytes, commits and polls the publish until
/// it is published or rejected; answers the last poll.
fn publishOne(nx: *Nx, token: []const u8, key: []const u8, version: []const u8, filename: []const u8, bytes: []const u8) !Reply {
    const begin_body = try nx.fmt("{{\"subdir\":\"noarch\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}", .{ filename, try nx.sha(bytes), bytes.len });
    const begun = try nx.call(.POST, try nx.fmt("/api/v2/packages/{s}/{s}/files", .{ key, version }), begin_body, token);
    try expectStatus(begun, 200);
    const id = str(begun.value, "upload_id");
    try expectStatus(try nx.call(.PUT, try nx.fmt("/_fake/upload/{s}", .{id}), bytes, null), 200);
    const committed = try nx.call(.POST, try nx.fmt("/api/v2/packages/{s}/{s}/publish", .{ key, version }), try nx.fmt("{{\"upload_ids\":[\"{s}\"]}}", .{id}), token);
    try expectStatus(committed, 202);
    const status_url = str(committed.value, "status_url");
    try std.testing.expect(std.mem.startsWith(u8, status_url, "/api/v2/publishes/"));
    var last: Reply = undefined;
    for (0..6) |_| {
        last = try nx.call(.GET, status_url, "", token);
        try expectStatus(last, 200);
        const s = str(last.value, "status");
        if (std.mem.eql(u8, s, "published") or std.mem.eql(u8, s, "rejected")) return last;
    }
    return error.TestUnexpectedResult;
}

test "a publish through v2 lands in index version 2 and the namespace's channel, under its conda name" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    const token = try nx.apiToken(alice, "[\"publish\",\"yank\"]", "[\"alice/json\"]");
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/alice/json", "", token), 201);
    const file = "mojo-alice.json-0.1.0-mojo1.0.0_0.conda";
    const done = try publishOne(&nx, token, "alice/json", "0.1.0", file, "json bytes");
    try std.testing.expectEqualStrings("published", str(done.value, "status"));
    try std.testing.expectEqualStrings("alice/json", str(done.value, "name"));

    const url = "http://fake.test/channel/alice/noarch/" ++ file;
    const record = try nx.file("index/v2/al/ic/alice/json");
    try std.testing.expect(contains(record, "\"name\":\"alice/json\""));
    try std.testing.expect(contains(record, "\"v\":2"));
    try std.testing.expect(contains(record, "\"url\":\"" ++ url ++ "\""));
    try std.testing.expect(contains(record, "\"filename\":\"" ++ file ++ "\""));
    const repodata = try nx.file("channel/alice/noarch/repodata.json");
    try std.testing.expect(contains(repodata, "\"name\":\"mojo-alice.json\""));
    try std.testing.expect(contains(try nx.file("channel/alice/noarch/current_repodata.json"), "\"name\":\"mojo-alice.json\""));
    // The flat root keeps a valid, empty repodata; index v1 has no line for it.
    try std.testing.expectEqualStrings(
        "{\"info\":{\"subdir\":\"noarch\"},\"packages\":{},\"packages.conda\":{},\"removed\":[]}\n",
        try nx.file("channel/noarch/repodata.json"),
    );
    try std.testing.expectError(error.FileNotFound, nx.file("index/al/ic/json"));
    // The bytes are served from the namespace's channel, as the record's URL says.
    const served = try nx.call(.GET, "/channel/alice/noarch/" ++ file, "", null);
    try expectStatus(served, 200);
    try std.testing.expectEqualStrings("json bytes", served.body);
    const version = try nx.call(.GET, "/api/v2/packages/alice/json/0.1.0", "", null);
    try expectStatus(version, 200);
    try std.testing.expectEqualStrings(url, str(version.value.object.get("files").?.array.items[0], "url"));
    const pkg = try nx.call(.GET, "/api/v2/packages/alice/json", "", null);
    try std.testing.expectEqualStrings("0.1.0", str(pkg.value, "latest"));

    // A file named with the v1 conda name does not name the package: rejected.
    const flat = try publishOne(&nx, token, "alice/json", "0.2.0", "mojo-json-0.2.0-mojo1.0.0_0.conda", "other bytes");
    try std.testing.expectEqualStrings("rejected", str(flat.value, "status"));
    try std.testing.expectEqualStrings("filename_mismatch", str(flat.value, "rejection_code"));

    // A yank through v2 shows in the record and the namespace's repodata.
    const yanked = try nx.call(.PUT, "/api/v2/packages/alice/json/0.1.0/yank", "{\"yanked\":true,\"reason\":\"broken\"}", token);
    try expectStatus(yanked, 200);
    try std.testing.expect(contains(try nx.file("index/v2/al/ic/alice/json"), "\"state\":\"yanked\""));
    try std.testing.expect(contains(try nx.file("channel/alice/noarch/repodata.json"), "\"removed\":[\"" ++ file ++ "\"]"));
}

test "config.json lists both index versions and the v2 API; a namespace's channel exists before it holds a package" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    _ = try nx.session("bob");
    const config = try nx.file("index/config.json");
    try std.testing.expect(contains(config, "\"index_version\":1,"));
    try std.testing.expect(contains(config, "\"index_versions\":[1,2]"));
    try std.testing.expect(contains(config, "\"api_v2_url\":\"http://fake.test/api/v2\""));
    try std.testing.expect(contains(config, "\"api_url\":\"http://fake.test/api/v1\""));
    try std.testing.expectEqualStrings("{\"index_version\":2,\"takedowns\":[]}\n", try nx.file("index/v2/takedowns.json"));
    try std.testing.expectEqualStrings("{\"index_version\":1,\"takedowns\":[]}\n", try nx.file("index/takedowns.json"));
    try std.testing.expectEqualStrings(
        "{\"info\":{\"subdir\":\"linux-64\"},\"packages\":{},\"packages.conda\":{},\"removed\":[]}\n",
        try nx.file("channel/bob/linux-64/repodata.json"),
    );
}

test "a rights check at use: a token of an account that left the organization cannot upload, commit or yank" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    const bob = try nx.session("bob");
    try nx.control("/_fake/org", "{\"login\":\"acme\",\"installed\":true,\"members\":[{\"handle\":\"alice\",\"role\":\"admin\"},{\"handle\":\"bob\",\"role\":\"member\"}]}");
    try expectStatus(try nx.call(.POST, "/api/v2/namespaces", "{\"namespace\":\"acme\"}", alice), 201);
    const token = try nx.apiToken(bob, "[\"publish\",\"yank\"]", "[\"acme/lib\"]");
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/acme/lib", "", token), 201);
    const done = try publishOne(&nx, token, "acme/lib", "1.0.0", "mojo-acme.lib-1.0.0-mojo1.0.0_0.conda", "lib");
    try std.testing.expectEqualStrings("published", str(done.value, "status"));
    try std.testing.expect(contains(try nx.file("index/v2/ac/me/acme/lib"), "\"name\":\"acme/lib\""));
    try nx.control("/_fake/org", "{\"login\":\"acme\",\"members\":[{\"handle\":\"alice\",\"role\":\"admin\"}]}");
    const body = try nx.fmt("{{\"subdir\":\"noarch\",\"filename\":\"mojo-acme.lib-1.0.1-mojo1.0.0_0.conda\",\"sha256\":\"{s}\",\"size\":3}}", .{try nx.sha("lib")});
    try expectCode(try nx.call(.POST, "/api/v2/packages/acme/lib/1.0.1/files", body, token), 403, "not_namespace_member");
    try expectCode(try nx.call(.POST, "/api/v2/packages/acme/lib/1.0.1/publish", "{\"upload_ids\":[\"x\"]}", token), 403, "not_namespace_member");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/acme/lib/1.0.0/yank", "{\"yanked\":true,\"reason\":\"x\"}", token), 403, "not_namespace_member");
    // The frozen namespace refuses every write, by its own error.
    try nx.control("/_fake/org", "{\"login\":\"acme\",\"installed\":false}");
    const session_yank = try nx.call(.PUT, "/api/v2/packages/acme/lib/1.0.0/yank", "{\"yanked\":true,\"reason\":\"x\"}", alice);
    try expectCode(session_yank, 403, "scope_missing");
    // v2 paths refuse a path whose namespace or version is malformed.
    try expectCode(try nx.call(.GET, "/api/v2/packages/Acme/lib/1.0.0", "", null), 400, "invalid_namespace");
    try expectCode(try nx.call(.GET, "/api/v2/packages/acme/lib/1.0", "", null), 400, "invalid_version");
    try expectCode(try nx.call(.GET, "/api/v2/packages/acme/lib/2.0.0", "", null), 404, "version_not_found");
    try expectCode(try nx.call(.GET, "/api/v2/packages/nope/lib/1.0.0", "", null), 404, "namespace_not_found");
}

/// A group create request for `keys` at `version` under v2: one noarch file each, named with its conda name.
fn groupRequest(nx: *Nx, keys: []const []const u8, version: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(nx.life.allocator());
    try out.appendSlice("{\"members\":[");
    for (keys, 0..) |k, i| {
        if (i > 0) try out.append(',');
        const slash = std.mem.indexOfScalar(u8, k, '/').?;
        const filename = try nx.fmt("mojo-{s}.{s}-{s}-mojo1.0.0_0.conda", .{ k[0..slash], k[slash + 1 ..], version });
        try out.writer().print("{{\"name\":\"{s}\",\"version\":\"{s}\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}]}}", .{ k, version, filename, try nx.sha(k), k.len });
    }
    try out.appendSlice("]}");
    return out.items;
}

test "a group through v2: members are full names in two namespaces, visible together in both channels" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    try nx.control("/_fake/org", "{\"login\":\"acme\",\"installed\":true,\"members\":[{\"handle\":\"alice\",\"role\":\"admin\"}]}");
    try expectStatus(try nx.call(.POST, "/api/v2/namespaces", "{\"namespace\":\"acme\"}", alice), 201);
    const members: []const []const u8 = &.{ "acme/core", "alice/app" };
    const token = try nx.apiToken(alice, "[\"publish\",\"yank\"]", "[\"acme/core\",\"alice/app\"]");
    for (members) |k| try expectStatus(try nx.call(.PUT, try nx.fmt("/api/v2/packages/{s}", .{k}), "", token), 201);
    // A v1 name in a v2 group is not a full name; a package not created is not found.
    try expectCode(try nx.call(.POST, "/api/v2/groups", try groupRequest(&nx, &.{"alice/app"}, "1.0.0"), alice), 403, "scope_missing");
    const flat = "{\"members\":[{\"name\":\"app\",\"version\":\"1.0.0\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"mojo-app-1.0.0-mojo1.0.0_0.conda\",\"sha256\":\"" ++ "0" ** 64 ++ "\",\"size\":1}]}]}";
    try expectCode(try nx.call(.POST, "/api/v2/groups", flat, token), 400, "invalid_name");

    const created = try nx.call(.POST, "/api/v2/groups", try groupRequest(&nx, members, "1.0.0"), token);
    try expectStatus(created, 201);
    const id = str(created.value, "group_id");
    for (created.value.object.get("members").?.array.items) |m| {
        const f = m.object.get("files").?.array.items[0];
        const name = str(m, "name");
        try expectStatus(try nx.call(.PUT, try nx.fmt("/_fake/upload/{s}", .{str(f, "upload_id")}), name, null), 200);
    }
    const commit = try nx.fmt("{{\"members\":[{{\"name\":\"acme/core\",\"manifest_sha256\":\"{s}\"}},{{\"name\":\"alice/app\",\"manifest_sha256\":\"{s}\"}}]}}", .{ try nx.sha("a"), try nx.sha("b") });
    const committed = try nx.call(.POST, try nx.fmt("/api/v2/groups/{s}/commit", .{id}), commit, token);
    try expectStatus(committed, 202);
    try std.testing.expect(std.mem.startsWith(u8, str(committed.value, "status_url"), "/api/v2/groups/"));
    var status: []const u8 = "";
    for (0..5) |_| {
        const r = try nx.call(.GET, try nx.fmt("/api/v2/groups/{s}", .{id}), "", token);
        try expectStatus(r, 200);
        status = str(r.value, "status");
        if (std.mem.eql(u8, status, "visible")) break;
    }
    try std.testing.expectEqualStrings("visible", status);
    try std.testing.expect(contains(try nx.file("channel/acme/noarch/repodata.json"), "\"name\":\"mojo-acme.core\""));
    try std.testing.expect(contains(try nx.file("channel/alice/noarch/repodata.json"), "\"name\":\"mojo-alice.app\""));
    try std.testing.expect(!contains(try nx.file("channel/alice/noarch/repodata.json"), "acme"));
    try std.testing.expect(contains(try nx.file("index/v2/ac/me/acme/core"), "\"v\":2"));
    try std.testing.expect(contains(try nx.file("index/v2/al/ic/alice/app"), "\"name\":\"alice/app\""));

    // Taken down: the v2 takedown log lists the full name, the v1 log does not, and the file answers 410.
    try nx.control("/_fake/tombstone", "{\"name\":\"alice/app\",\"version\":\"1.0.0\",\"reason_code\":\"malware\"}");
    try std.testing.expect(contains(try nx.file("index/v2/takedowns.json"), "\"name\":\"alice/app\""));
    try std.testing.expect(!contains(try nx.file("index/takedowns.json"), "alice"));
    try expectStatus(try nx.call(.GET, "/channel/alice/noarch/mojo-alice.app-1.0.0-mojo1.0.0_0.conda", "", null), 410);
    try std.testing.expect(!contains(try nx.file("index/v2/al/ic/alice/app"), "\"url\""));

    // The group's yank needs the namespaces to be writable now: frozen, it is refused by the namespace's error.
    try nx.control("/_fake/org", "{\"login\":\"acme\",\"installed\":false}");
    try expectCode(try nx.call(.PUT, try nx.fmt("/api/v2/groups/{s}/yank", .{id}), "{\"yanked\":true,\"reason\":\"x\"}", token), 403, "namespace_unverified");
}

test "the v2 OIDC exchange is matched to a namespace's publishers and creates nothing; its token creates and publishes" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    try nx.control("/_fake/org", "{\"login\":\"acme\",\"installed\":true,\"members\":[{\"handle\":\"alice\",\"role\":\"admin\"}]}");
    try expectStatus(try nx.call(.POST, "/api/v2/namespaces", "{\"namespace\":\"acme\"}", alice), 201);
    try nx.control("/_fake/trusted", "{\"namespace\":\"acme\",\"repository\":\"acme/release\"}");
    const jwt = try t.jwtFor(&nx, "acme/release");
    const other = try t.jwtFor(&nx, "someone/else");

    const ex = "{{\"jwt\":\"{s}\",\"name\":\"{s}\",\"version\":\"1.0.0\"}}";
    try expectCode(try nx.call(.POST, "/api/v2/auth/oidc/exchange", try nx.fmt(ex, .{ other, "acme/lib" }), null), 403, "oidc_not_trusted");
    try expectCode(try nx.call(.POST, "/api/v2/auth/oidc/exchange", try nx.fmt(ex, .{ jwt, "alice/lib" }), null), 403, "oidc_not_trusted");
    try expectCode(try nx.call(.POST, "/api/v2/auth/oidc/exchange", try nx.fmt(ex, .{ jwt, "ghost/lib" }), null), 403, "oidc_not_trusted");
    try expectCode(try nx.call(.POST, "/api/v2/auth/oidc/exchange", try nx.fmt(ex, .{ jwt, "lib" }), null), 400, "invalid_name");
    try expectCode(try nx.call(.POST, "/api/v2/auth/oidc/exchange", try nx.fmt(ex, .{ "not-a-jwt", "acme/lib" }), null), 401, "oidc_token_invalid");
    const minted = try nx.call(.POST, "/api/v2/auth/oidc/exchange", try nx.fmt(ex, .{ jwt, "acme/lib" }), null);
    try expectStatus(minted, 200);
    try std.testing.expectEqualStrings("acme/lib", str(minted.value, "name"));
    try std.testing.expectEqualStrings("publish", str(minted.value, "token_kind"));
    try std.testing.expect(nx.state.packageByName("acme/lib") == null);
    const token = str(minted.value, "token");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/acme/other", "", token), 403, "scope_missing");
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/acme/lib", "", token), 201);
    const done = try publishOne(&nx, token, "acme/lib", "1.0.0", "mojo-acme.lib-1.0.0-mojo1.0.0_0.conda", "ci bytes");
    try std.testing.expectEqualStrings("published", str(done.value, "status"));
    try std.testing.expect(contains(try nx.file("index/v2/ac/me/acme/lib"), "\"repository\":\"acme/release\""));

    // The packages form: every name's namespace must have the publisher, else the name is refused.
    const set = "{{\"jwt\":\"{s}\",\"purpose\":\"stage\",\"packages\":[{{\"name\":\"acme/lib\",\"version\":\"1.1.0\"}},{{\"name\":\"{s}\",\"version\":\"1.0.0\"}}]}}";
    const refused = try nx.call(.POST, "/api/v2/auth/oidc/exchange", try nx.fmt(set, .{ jwt, "alice/app" }), null);
    try expectCode(refused, 403, "oidc_not_trusted");
    try std.testing.expectEqualStrings("No trusted publisher of 'alice/app' matches this CI identity.", str(refused.value.object.get("error").?, "message"));
    try expectCode(try nx.call(.POST, "/api/v2/auth/oidc/exchange", try nx.fmt(set, .{ jwt, "acme/lib" }), null), 400, "invalid_request");
    const staged = try nx.call(.POST, "/api/v2/auth/oidc/exchange", try nx.fmt(set, .{ jwt, "acme/new_one" }), null);
    try expectStatus(staged, 200);
    try std.testing.expectEqualStrings("stage", str(staged.value, "token_kind"));
    try std.testing.expectEqual(@as(usize, 2), staged.value.object.get("packages").?.array.items.len);
    try std.testing.expect(nx.state.packageByName("acme/new_one") == null);
    // Its token may create the packages it names, in a namespace whose publisher it is.
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/acme/new_one", "", str(staged.value, "token")), 201);
}
