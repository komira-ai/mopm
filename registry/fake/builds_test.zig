//! Unit tests of the builds of a version (builds.zig, and what publish.zig, groups.zig and files.zig do with them), by behaviour:
//! each test sends requests through `api.handle`, as the server does, and reads the answers as a client would. A version keeps the
//! files of several builds; a single publish or a group member whose version is published adds one build to it. The fake opens no
//! archive, so the manifest a commit states is the only thing that says two builds come from the same sources.

const std = @import("std");
const Value = std.json.Value;
const g = @import("groups_test.zig");
const Fx = g.Fx;
const Reply = g.Reply;
const expectCode = g.expectCode;
const idOf = g.idOf;
const nt = @import("namespaces_test.zig");
const Nx = nt.Nx;

// ---------------------------------------------------------------------------
// Single publishes of v1 packages
// ---------------------------------------------------------------------------

fn fileName(fx: *Fx, name: []const u8, version: []const u8, compiler: []const u8) ![]const u8 {
    return std.fmt.allocPrint(fx.life.allocator(), "mojo-{s}-{s}-mojo{s}_0.conda", .{ name, version, compiler });
}

/// Begins an upload of `content` as the build of `compiler` for `subdir` of `name` `version`, PUTs the bytes, and answers the upload id.
fn put(fx: *Fx, name: []const u8, version: []const u8, subdir: []const u8, compiler: []const u8, content: []const u8) ![]const u8 {
    const a = fx.life.allocator();
    const body = try std.fmt.allocPrint(a,
        \\{{"subdir":"{s}","filename":"{s}","sha256":"{s}","size":{d}}}
    , .{ subdir, try fileName(fx, name, version, compiler), try fx.sha(content), content.len });
    const begun = try fx.call(.POST, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/{s}/files", .{ name, version }), body, fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), begun.status);
    const id = begun.value.object.get("upload_id").?.string;
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, try std.fmt.allocPrint(a, "/_fake/upload/{s}", .{id}), content, null)).status);
    return id;
}

/// The commit of the uploads `ids`; `manifest` is the `manifest_sha256` it states, or null for none.
fn commit(fx: *Fx, name: []const u8, version: []const u8, ids: []const []const u8, manifest: ?[]const u8) !Reply {
    const a = fx.life.allocator();
    var body = std.ArrayList(u8).init(a);
    try body.appendSlice("{\"upload_ids\":[");
    for (ids, 0..) |id, i| try body.writer().print("{s}\"{s}\"", .{ if (i > 0) "," else "", id });
    try body.append(']');
    if (manifest) |m| try body.writer().print(",\"manifest_sha256\":\"{s}\"", .{m});
    try body.append('}');
    return fx.call(.POST, try std.fmt.allocPrint(a, "/api/v1/packages/{s}/{s}/publish", .{ name, version }), body.items, fx.alice_token);
}

/// Polls the publish `r` accepted four times, which is as far as a publish goes (it shows `published`, or `rejected`); answers the last poll.
fn settle(fx: *Fx, r: Reply) !Reply {
    try std.testing.expectEqual(@as(u16, 202), r.status);
    const url = r.value.object.get("status_url").?.string;
    var last: Reply = undefined;
    for (0..4) |_| last = try fx.call(.GET, url, "", fx.alice_token);
    return last;
}

/// A published version of `name` with the one build of `compiler`, whose manifest is `manifest`.
fn publishOne(fx: *Fx, name: []const u8, version: []const u8, compiler: []const u8, content: []const u8, manifest: []const u8) !void {
    const id = try put(fx, name, version, "linux-64", compiler, content);
    const last = try settle(fx, try commit(fx, name, version, &.{id}, manifest));
    try std.testing.expectEqualStrings("published", last.value.object.get("status").?.string);
}

fn getVersion(fx: *Fx, prefix: []const u8, name: []const u8, version: []const u8) !Reply {
    return fx.call(.GET, try std.fmt.allocPrint(fx.life.allocator(), "{s}/packages/{s}/{s}", .{ prefix, name, version }), "", null);
}

fn filenames(fx: *Fx, files: []const Value) ![]const u8 {
    var out = std.ArrayList(u8).init(fx.life.allocator());
    for (files, 0..) |f, i| try out.writer().print("{s}{s}", .{ if (i > 0) " " else "", f.object.get("filename").?.string });
    return out.items;
}

/// The message `version_exists` carries for `name` `version` whose first file has the bytes `first`: the catalogue's, whatever the
/// refusal (the contract's replay holds every `version_exists` to that template).
fn exists(fx: *Fx, name: []const u8, version: []const u8, first: []const u8) ![]const u8 {
    return std.fmt.allocPrint(fx.life.allocator(), "'{s}' {s} already exists (sha256 {s}); versions are immutable.", .{ name, version, try fx.sha(first) });
}

fn expectExists(r: Reply, message: []const u8) !void {
    try expectCode(r, 409, "version_exists");
    try std.testing.expectEqualStrings(message, r.value.object.get("error").?.object.get("message").?.string);
    try std.testing.expectEqualStrings("Publish a new version.", r.value.object.get("error").?.object.get("hint").?.string);
}

test "a new version is published with files of several builds, and v1 shows its lowest build only" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const high = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.2.0", "high");
    const low = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.0.0", "low");
    const done = try settle(&fx, try commit(&fx, "pkg_a", "1.0.0", &.{ high, low }, try fx.sha("manifest")));
    try std.testing.expectEqualStrings("published", done.value.object.get("status").?.string);

    // getVersion under /api/v1: the primary build (the lowest compiler, whatever the order of the commit), and no `builds`.
    const v = try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0");
    try std.testing.expectEqual(@as(u16, 200), v.status);
    try std.testing.expectEqualStrings("==1.0.0", v.value.object.get("requires_mojo").?.string);
    try std.testing.expectEqualStrings("mojo-pkg_a-1.0.0-mojo1.0.0_0.conda", try filenames(&fx, v.value.object.get("files").?.array.items));
    try std.testing.expect(v.value.object.get("builds") == null);

    // The v1 index line is the one it always was: the primary build, no `builds`.
    const line = try fx.call(.GET, "/index/pk/g_/pkg_a", "", null);
    try std.testing.expectEqualStrings("mojo1.0.0_0", line.value.object.get("build").?.string);
    try std.testing.expectEqualStrings("==1.0.0", line.value.object.get("requires_mojo").?.string);
    try std.testing.expectEqualStrings("mojo-pkg_a-1.0.0-mojo1.0.0_0.conda", try filenames(&fx, line.value.object.get("files").?.array.items));
    try std.testing.expect(line.value.object.get("builds") == null);
    try std.testing.expectEqual(@as(i64, 1), line.value.object.get("v").?.integer);

    // The repodata lists every file, each with its own build and compiler.
    const repodata = try fx.call(.GET, "/channel/linux-64/repodata.json", "", null);
    const entries = repodata.value.object.get("packages.conda").?.object;
    try std.testing.expectEqual(@as(usize, 2), entries.count());
    const hi = entries.get("mojo-pkg_a-1.0.0-mojo1.2.0_0.conda").?.object;
    try std.testing.expectEqualStrings("mojo1.2.0_0", hi.get("build").?.string);
    try std.testing.expectEqualStrings("mojo-compiler ==1.2.0", hi.get("depends").?.array.items[0].string);
    const lo = entries.get("mojo-pkg_a-1.0.0-mojo1.0.0_0.conda").?.object;
    try std.testing.expectEqualStrings("mojo1.0.0_0", lo.get("build").?.string);
    try std.testing.expectEqualStrings("mojo-compiler ==1.0.0", lo.get("depends").?.array.items[0].string);
}

test "a build is added to a published version: appended when published, the version's other fields stay" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.2.0", "high", m);
    const before = try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0");
    try std.testing.expectEqualStrings("==1.2.0", before.value.object.get("requires_mojo").?.string);

    const id = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.0.0", "low");
    const accepted = try commit(&fx, "pkg_a", "1.0.0", &.{id}, m);
    try std.testing.expectEqual(@as(u16, 202), accepted.status);
    // Nothing shows while the publish is pending or validating; the poll that shows `indexing` has appended the build.
    const url = accepted.value.object.get("status_url").?.string;
    for ([_][]const u8{ "pending", "validating" }) |want| {
        const shown = try fx.call(.GET, url, "", fx.alice_token);
        try std.testing.expectEqualStrings(want, shown.value.object.get("status").?.string);
        const now = try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0");
        try std.testing.expectEqual(@as(usize, 1), now.value.object.get("files").?.array.items.len);
        try std.testing.expectEqualStrings("==1.2.0", now.value.object.get("requires_mojo").?.string);
    }
    try std.testing.expectEqualStrings("indexing", (try fx.call(.GET, url, "", fx.alice_token)).value.object.get("status").?.string);
    try std.testing.expectEqualStrings("published", (try fx.call(.GET, url, "", fx.alice_token)).value.object.get("status").?.string);

    // The added build is the lowest: it is now the primary, and the version's own fields are what they were.
    const after = try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0");
    try std.testing.expectEqualStrings("==1.0.0", after.value.object.get("requires_mojo").?.string);
    try std.testing.expectEqualStrings("mojo-pkg_a-1.0.0-mojo1.0.0_0.conda", try filenames(&fx, after.value.object.get("files").?.array.items));
    try std.testing.expectEqualStrings("published", after.value.object.get("state").?.string);
    try std.testing.expectEqualStrings(m, after.value.object.get("manifest_sha256").?.string);
    try std.testing.expectEqualStrings(before.value.object.get("published_at").?.string, after.value.object.get("published_at").?.string);
    // The bytes are served, and the repodata lists both files.
    const served = try fx.call(.GET, "/channel/linux-64/mojo-pkg_a-1.0.0-mojo1.0.0_0.conda", "", null);
    try std.testing.expectEqualStrings("low", served.body);
    const repodata = try fx.call(.GET, "/channel/linux-64/repodata.json", "", null);
    try std.testing.expectEqual(@as(usize, 2), repodata.value.object.get("packages.conda").?.object.count());
    // The same upload ids again resume that publish.
    try std.testing.expectEqualStrings(accepted.value.object.get("publish_id").?.string, (try commit(&fx, "pkg_a", "1.0.0", &.{id}, m)).value.object.get("publish_id").?.string);
}

test "a build is refused, version_exists, when the version has it, when the files are of several builds, and when the manifest differs" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.0.0", "low", m);

    // A build the version has: a published file is never replaced.
    const again = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.0.0", "other bytes");
    try expectExists(try commit(&fx, "pkg_a", "1.0.0", &.{again}, m), try exists(&fx, "pkg_a", "1.0.0", "low"));
    // Files of two builds in one commit: one Mojo build per publish.
    const b11 = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.1.0", "eleven");
    const b12 = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.2.0", "twelve");
    try expectExists(try commit(&fx, "pkg_a", "1.0.0", &.{ b11, b12 }, m), try exists(&fx, "pkg_a", "1.0.0", "low"));
    // Other sources: another manifest, or none (the fake then holds the sha256 of the first file, which is not the version's).
    try expectExists(try commit(&fx, "pkg_a", "1.0.0", &.{b11}, try fx.sha("another manifest")), try exists(&fx, "pkg_a", "1.0.0", "low"));
    try expectExists(try commit(&fx, "pkg_a", "1.0.0", &.{b11}, null), try exists(&fx, "pkg_a", "1.0.0", "low"));

    // A refusal uses up no upload and changes nothing: the same uploads commit once the request is right.
    try std.testing.expectEqual(@as(usize, 1), (try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0")).value.object.get("files").?.array.items.len);
    const done = try settle(&fx, try commit(&fx, "pkg_a", "1.0.0", &.{b11}, m));
    try std.testing.expectEqualStrings("published", done.value.object.get("status").?.string);
    // Files of one build, for two platforms, are one build.
    const mac = try put(&fx, "pkg_a", "1.0.0", "osx-arm64", "1.2.0", "twelve mac");
    const linux = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.2.0", "twelve linux");
    const both = try settle(&fx, try commit(&fx, "pkg_a", "1.0.0", &.{ mac, linux }, m));
    try std.testing.expectEqualStrings("published", both.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 3), (try fx.call(.GET, "/channel/linux-64/repodata.json", "", null)).value.object.get("packages.conda").?.object.count());
    try std.testing.expectEqual(@as(usize, 1), (try fx.call(.GET, "/channel/osx-arm64/repodata.json", "", null)).value.object.get("packages.conda").?.object.count());
}

test "a version committed without manifest_sha256 holds its first file's sha256, which an added build must state" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const id = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.0.0", "low");
    const done = try settle(&fx, try commit(&fx, "pkg_a", "1.0.0", &.{id}, null));
    try std.testing.expectEqualStrings("published", done.value.object.get("status").?.string);

    const eleven = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.1.0", "eleven");
    try expectExists(try commit(&fx, "pkg_a", "1.0.0", &.{eleven}, try fx.sha("manifest")), try exists(&fx, "pkg_a", "1.0.0", "low"));
    const added = try settle(&fx, try commit(&fx, "pkg_a", "1.0.0", &.{eleven}, try fx.sha("low")));
    try std.testing.expectEqualStrings("published", added.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 2), (try fx.call(.GET, "/channel/linux-64/repodata.json", "", null)).value.object.get("packages.conda").?.object.count());
}

test "a version that is yanked or taken down takes no build; a rejected one keeps its plain refusal" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.0.0", "low", m);
    try publishOne(&fx, "pkg_b", "1.0.0", "1.0.0", "low", m);

    const yanked = try fx.call(.PUT, "/api/v1/packages/pkg_a/1.0.0/yank", "{\"yanked\":true,\"reason\":\"bad\"}", fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), yanked.status);
    const a_id = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.1.0", "eleven");
    try expectExists(try commit(&fx, "pkg_a", "1.0.0", &.{a_id}, m), try exists(&fx, "pkg_a", "1.0.0", "low"));

    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.POST, "/_fake/tombstone", "{\"name\":\"pkg_b\",\"version\":\"1.0.0\",\"reason_code\":\"malware\"}", null)).status);
    const b_id = try put(&fx, "pkg_b", "1.0.0", "linux-64", "1.1.0", "eleven");
    try expectExists(try commit(&fx, "pkg_b", "1.0.0", &.{b_id}, m), try exists(&fx, "pkg_b", "1.0.0", "low"));

    // A version whose publish was rejected holds its number: the plain catalogue message, as before.
    const bad = try put(&fx, "pkg_c", "1.0.0", "linux-64", "1.0.0", "REJECT:archive_invalid");
    const last = try settle(&fx, try commit(&fx, "pkg_c", "1.0.0", &.{bad}, m));
    try std.testing.expectEqualStrings("rejected", last.value.object.get("status").?.string);
    const c_id = try put(&fx, "pkg_c", "1.0.0", "linux-64", "1.1.0", "eleven");
    try expectExists(try commit(&fx, "pkg_c", "1.0.0", &.{c_id}, m), try exists(&fx, "pkg_c", "1.0.0", "REJECT:archive_invalid"));
}

test "a build whose publish is rejected leaves the version as it is and is not free again; a build in flight is held" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.0.0", "low", m);

    const bad = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.1.0", "REJECT:manifest_invalid");
    const last = try settle(&fx, try commit(&fx, "pkg_a", "1.0.0", &.{bad}, m));
    try std.testing.expectEqualStrings("rejected", last.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("manifest_invalid", last.value.object.get("rejection_code").?.string);
    const v = try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0");
    try std.testing.expectEqualStrings("published", v.value.object.get("state").?.string);
    try std.testing.expectEqualStrings("mojo-pkg_a-1.0.0-mojo1.0.0_0.conda", try filenames(&fx, v.value.object.get("files").?.array.items));
    // The rejected build is burned, as a rejected version is.
    const retry = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.1.0", "fixed");
    try expectExists(try commit(&fx, "pkg_a", "1.0.0", &.{retry}, m), try exists(&fx, "pkg_a", "1.0.0", "low"));

    // A build another publish is still running is held, and a different build is free.
    const first = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.2.0", "first");
    try std.testing.expectEqual(@as(u16, 202), (try commit(&fx, "pkg_a", "1.0.0", &.{first}, m)).status);
    const second = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.2.0", "second");
    try expectExists(try commit(&fx, "pkg_a", "1.0.0", &.{second}, m), try exists(&fx, "pkg_a", "1.0.0", "low"));
    const third = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.3.0", "third");
    try std.testing.expectEqual(@as(u16, 202), (try commit(&fx, "pkg_a", "1.0.0", &.{third}, m)).status);
}

test "a build accepted for a version that is taken down before it is published is dropped, with its bytes" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.0.0", "low", m);
    const id = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.1.0", "eleven");
    const accepted = try commit(&fx, "pkg_a", "1.0.0", &.{id}, m);
    try std.testing.expectEqual(@as(u16, 202), accepted.status);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.POST, "/_fake/tombstone", "{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"reason_code\":\"malware\"}", null)).status);
    const last = try settle(&fx, accepted);
    try std.testing.expectEqualStrings("published", last.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 1), (try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0")).value.object.get("files").?.array.items.len);
    try std.testing.expectEqual(@as(u16, 404), (try fx.call(.GET, "/channel/linux-64/mojo-pkg_a-1.0.0-mojo1.1.0_0.conda", "", null)).status);
}

// ---------------------------------------------------------------------------
// Groups
// ---------------------------------------------------------------------------

/// A member of a create request: `name` `version` with the one file of the build of `compiler`, whose bytes are `content`.
fn member(fx: *Fx, name: []const u8, version: []const u8, compiler: []const u8, content: []const u8) ![]const u8 {
    return std.fmt.allocPrint(fx.life.allocator(),
        \\{{"name":"{s}","version":"{s}","files":[{{"subdir":"linux-64","filename":"{s}","sha256":"{s}","size":{d}}}]}}
    , .{ name, version, try fileName(fx, name, version, compiler), try fx.sha(content), content.len });
}

fn createOf(fx: *Fx, members: []const []const u8) !Reply {
    const a = fx.life.allocator();
    return fx.call(.POST, "/api/v1/groups", try std.fmt.allocPrint(a, "{{\"members\":[{s}]}}", .{try std.mem.join(a, ",", members)}), fx.alice_token);
}

/// PUTs the bytes of the files a create answer asks for, in the order of its members, `contents[i]` for the one file of member `i`.
fn putAll(fx: *Fx, created: Reply, contents: []const []const u8) !void {
    for (created.value.object.get("members").?.array.items, contents) |m, content| {
        const f = m.object.get("files").?.array.items[0].object;
        if (f.get("uploaded").?.bool) continue;
        const path = try std.fmt.allocPrint(fx.life.allocator(), "/_fake/upload/{s}", .{f.get("upload_id").?.string});
        try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, path, content, null)).status);
    }
}

/// The commit of group `id` stating `manifests` for its members: a member `(name, manifest)`, a null manifest for none.
fn commitGroupOf(fx: *Fx, id: []const u8, members: []const struct { []const u8, ?[]const u8 }) !Reply {
    const a = fx.life.allocator();
    var body = std.ArrayList(u8).init(a);
    try body.appendSlice("{\"members\":[");
    for (members, 0..) |m, i| {
        if (i > 0) try body.append(',');
        try body.writer().print("{{\"name\":\"{s}\"", .{m[0]});
        if (m[1]) |x| try body.writer().print(",\"manifest_sha256\":\"{s}\"", .{x});
        try body.append('}');
    }
    try body.appendSlice("]}");
    return fx.call(.POST, try std.fmt.allocPrint(a, "/api/v1/groups/{s}/commit", .{id}), body.items, fx.alice_token);
}

fn groupOf(fx: *Fx, id: []const u8) !Reply {
    return fx.call(.GET, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{id}), "", fx.alice_token);
}

/// Polls group `id` until it is `visible` (it takes three polls after the commit); the last answer.
fn visible(fx: *Fx, id: []const u8) !Reply {
    var last: Reply = undefined;
    for (0..3) |_| last = try groupOf(fx, id);
    try std.testing.expectEqualStrings("visible", last.value.object.get("status").?.string);
    return last;
}

test "a group member whose version is published adds a build: reserved at create, appended when the group is visible" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.2.0", "high", m);
    const before = try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0");

    const created = try createOf(&fx, &.{try member(&fx, "pkg_a", "1.0.0", "1.0.0", "low")});
    try std.testing.expectEqual(@as(u16, 201), created.status);
    const answer = created.value.object.get("members").?.array.items[0].object;
    try std.testing.expectEqualStrings("new", answer.get("action").?.string);
    try std.testing.expect(answer.get("files").?.array.items[0].object.get("put_url") != null);
    // The group lists the declared file, and the version is as it was.
    const id = idOf(created);
    const open = try groupOf(&fx, id);
    try std.testing.expectEqual(@as(usize, 1), open.value.object.get("members").?.array.items[0].object.get("files").?.array.items.len);
    try putAll(&fx, created, &.{"low"});
    try std.testing.expectEqual(@as(u16, 202), (try commitGroupOf(&fx, id, &.{.{ "pkg_a", m }})).status);

    // validating: nothing yet; committed (shown): nothing yet; the move after it appends the build.
    try std.testing.expectEqualStrings("validating", (try groupOf(&fx, id)).value.object.get("status").?.string);
    try std.testing.expectEqualStrings("==1.2.0", (try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0")).value.object.get("requires_mojo").?.string);
    try std.testing.expectEqualStrings("committed", (try groupOf(&fx, id)).value.object.get("status").?.string);
    const shown = try groupOf(&fx, id);
    try std.testing.expectEqualStrings("visible", shown.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("published", shown.value.object.get("members").?.array.items[0].object.get("state").?.string);

    const after = try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0");
    try std.testing.expectEqualStrings("==1.0.0", after.value.object.get("requires_mojo").?.string);
    try std.testing.expectEqualStrings("mojo-pkg_a-1.0.0-mojo1.0.0_0.conda", try filenames(&fx, after.value.object.get("files").?.array.items));
    try std.testing.expectEqualStrings("published", after.value.object.get("state").?.string);
    try std.testing.expectEqualStrings(m, after.value.object.get("manifest_sha256").?.string);
    try std.testing.expectEqualStrings(before.value.object.get("published_at").?.string, after.value.object.get("published_at").?.string);
    // The group did not publish the version: it names no group.
    try std.testing.expect(after.value.object.get("group_id") == null);
    try std.testing.expectEqualStrings("low", (try fx.call(.GET, "/channel/linux-64/mojo-pkg_a-1.0.0-mojo1.0.0_0.conda", "", null)).body);
}

test "a group create refuses an add member whose build exists, whose files are of several builds, or whose version is yanked" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.0.0", "low", m);
    try publishOne(&fx, "pkg_b", "1.0.0", "1.0.0", "low", m);
    const new_member = try member(&fx, "pkg_c", "1.0.0", "1.0.0", "fresh");

    const have = try createOf(&fx, &.{ try member(&fx, "pkg_a", "1.0.0", "1.0.0", "other"), new_member });
    try expectExists(have, try exists(&fx, "pkg_a", "1.0.0", "low"));
    const two_builds = try std.fmt.allocPrint(fx.life.allocator(),
        \\{{"name":"pkg_a","version":"1.0.0","files":[{{"subdir":"linux-64","filename":"{s}","sha256":"{s}","size":1}},{{"subdir":"osx-arm64","filename":"{s}","sha256":"{s}","size":1}}]}}
    , .{ try fileName(&fx, "pkg_a", "1.0.0", "1.1.0"), try fx.sha("x"), try fileName(&fx, "pkg_a", "1.0.0", "1.2.0"), try fx.sha("y") });
    try expectExists(try createOf(&fx, &.{two_builds}), try exists(&fx, "pkg_a", "1.0.0", "low"));
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, "/api/v1/packages/pkg_b/1.0.0/yank", "{\"yanked\":true,\"reason\":\"bad\"}", fx.alice_token)).status);
    try expectExists(try createOf(&fx, &.{try member(&fx, "pkg_b", "1.0.0", "1.1.0", "eleven")}), try exists(&fx, "pkg_b", "1.0.0", "low"));
    // None of these reserved anything: pkg_c's number is free.
    try std.testing.expectEqual(@as(u16, 201), (try createOf(&fx, &.{new_member})).status);
}

test "a group commit compares an add member's manifest with the version's, and leaves the group open when it differs" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.0.0", "low", m);
    const created = try createOf(&fx, &.{try member(&fx, "pkg_a", "1.0.0", "1.1.0", "eleven")});
    const id = idOf(created);
    try putAll(&fx, created, &.{"eleven"});

    const other = try exists(&fx, "pkg_a", "1.0.0", "low");
    try expectExists(try commitGroupOf(&fx, id, &.{.{ "pkg_a", try fx.sha("another manifest") }}), other);
    try expectExists(try commitGroupOf(&fx, id, &.{.{ "pkg_a", null }}), other);
    try std.testing.expectEqualStrings("open", try fx.status(id));
    try std.testing.expectEqual(@as(u16, 202), (try commitGroupOf(&fx, id, &.{.{ "pkg_a", m }})).status);
    _ = try visible(&fx, id);
    try std.testing.expectEqual(@as(usize, 1), (try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0")).value.object.get("files").?.array.items.len);
    try std.testing.expectEqualStrings("==1.0.0", (try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0")).value.object.get("requires_mojo").?.string);
    try std.testing.expectEqualStrings("published", (try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0")).value.object.get("state").?.string);
    try std.testing.expectEqual(@as(usize, 2), (try fx.call(.GET, "/channel/linux-64/repodata.json", "", null)).value.object.get("packages.conda").?.object.count());
}

test "a version a group published takes a build from a later group that states the manifest of the first commit" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const first = try fx.call(.POST, "/api/v1/groups", try fx.request(g.abc, "1.0.0", "x"), fx.alice_token);
    try fx.upload(first, "x");
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/commit", .{idOf(first)}), try fx.commitBody(g.abc), fx.alice_token)).status);
    _ = try visible(&fx, idOf(first));

    // The version holds the sha256 of its first file (the group's way); a build must state what the commit stated: sha256("pkg_a").
    const created = try createOf(&fx, &.{try member(&fx, "pkg_a", "1.0.0", "1.1.0", "eleven")});
    try putAll(&fx, created, &.{"eleven"});
    const id = idOf(created);
    try expectExists(try commitGroupOf(&fx, id, &.{.{ "pkg_a", try fx.sha("not pkg_a") }}), try exists(&fx, "pkg_a", "1.0.0", "pkg_ax"));
    try std.testing.expectEqual(@as(u16, 202), (try commitGroupOf(&fx, id, &.{.{ "pkg_a", try fx.sha("pkg_a") }})).status);
    _ = try visible(&fx, id);
    const v = try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0");
    try std.testing.expectEqualStrings(idOf(first), v.value.object.get("group_id").?.string);
    try std.testing.expectEqualStrings(try fx.sha("pkg_ax"), v.value.object.get("manifest_sha256").?.string);
    // The group's own file is in noarch, the added build's in linux-64.
    try std.testing.expectEqual(@as(usize, 3), (try fx.call(.GET, "/channel/noarch/repodata.json", "", null)).value.object.get("packages.conda").?.object.count());
    try std.testing.expectEqualStrings("mojo-pkg_a-1.0.0-mojo1.1.0_0.conda", (try fx.call(.GET, "/channel/linux-64/repodata.json", "", null)).value.object.get("packages.conda").?.object.keys()[0]);
}

test "a group yank acts on whole versions: it yanks the new versions of a group, and nothing for a group of added builds" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.0.0", "low", m);
    try publishOne(&fx, "pkg_c", "1.0.0", "1.0.0", "low", m);

    // pkg_a adds a build and pkg_b is new, in one group.
    const mixed = try createOf(&fx, &.{ try member(&fx, "pkg_a", "1.0.0", "1.1.0", "eleven"), try member(&fx, "pkg_b", "2.0.0", "1.0.0", "fresh") });
    try putAll(&fx, mixed, &.{ "eleven", "fresh" });
    try std.testing.expectEqual(@as(u16, 202), (try commitGroupOf(&fx, idOf(mixed), &.{ .{ "pkg_a", m }, .{ "pkg_b", null } })).status);
    _ = try visible(&fx, idOf(mixed));
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.PUT, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/yank", .{idOf(mixed)}), "{\"yanked\":true,\"reason\":\"bad\"}", fx.alice_token)).status);
    _ = try groupOf(&fx, idOf(mixed)); // a poll shows the yank in the stage it was in, then moves it on
    const yanked = try groupOf(&fx, idOf(mixed));
    try std.testing.expectEqual(@as(i64, 1), yanked.value.object.get("yank").?.object.get("yanked_members").?.integer);
    try std.testing.expectEqualStrings("published", (try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0")).value.object.get("state").?.string);
    try std.testing.expectEqualStrings("yanked", (try getVersion(&fx, "/api/v1", "pkg_b", "2.0.0")).value.object.get("state").?.string);
    // The unyank restores what the yank changed, and only that.
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.PUT, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/yank", .{idOf(mixed)}), "{\"yanked\":false}", fx.alice_token)).status);
    _ = try groupOf(&fx, idOf(mixed));
    try std.testing.expectEqualStrings("published", (try getVersion(&fx, "/api/v1", "pkg_b", "2.0.0")).value.object.get("state").?.string);

    // A group whose members all add builds: its yank settles as yanked with no member changed, and the versions stay published.
    const adds = try createOf(&fx, &.{try member(&fx, "pkg_c", "1.0.0", "1.1.0", "eleven")});
    try putAll(&fx, adds, &.{"eleven"});
    try std.testing.expectEqual(@as(u16, 202), (try commitGroupOf(&fx, idOf(adds), &.{.{ "pkg_c", m }})).status);
    _ = try visible(&fx, idOf(adds));
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.PUT, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/yank", .{idOf(adds)}), "{\"yanked\":true,\"reason\":\"bad\"}", fx.alice_token)).status);
    _ = try groupOf(&fx, idOf(adds));
    const settled = try groupOf(&fx, idOf(adds));
    const yank = settled.value.object.get("yank").?.object;
    try std.testing.expectEqualStrings("yanked", yank.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 0), yank.get("yanked_members").?.integer);
    try std.testing.expectEqualStrings("published", settled.value.object.get("members").?.array.items[0].object.get("state").?.string);
    const v = try getVersion(&fx, "/api/v1", "pkg_c", "1.0.0");
    try std.testing.expectEqualStrings("published", v.value.object.get("state").?.string);
    try std.testing.expectEqual(@as(usize, 1), v.value.object.get("files").?.array.items.len);
    // Its unyank has nothing to restore.
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.PUT, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}/yank", .{idOf(adds)}), "{\"yanked\":false}", fx.alice_token)).status);
    _ = try groupOf(&fx, idOf(adds));
    try std.testing.expectEqualStrings("restored", (try groupOf(&fx, idOf(adds))).value.object.get("yank").?.object.get("state").?.string);
}

test "a build in a group that is running is held against other adds, and a build another publish took is refused at the group's commit" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.0.0", "low", m);

    try publishOne(&fx, "pkg_c", "1.0.0", "1.0.0", "low", m);

    // A group that is validating holds its build: another group or a single publish cannot take it. Its other members, a new version
    // and a build of another version, hold nothing of pkg_a's or pkg_c's.
    const one = try createOf(&fx, &.{
        try member(&fx, "pkg_a", "1.0.0", "1.1.0", "eleven"),
        try member(&fx, "pkg_b", "1.0.0", "1.0.0", "fresh"),
        try member(&fx, "pkg_c", "1.0.0", "1.1.0", "eleven c"),
    });
    try putAll(&fx, one, &.{ "eleven", "fresh", "eleven c" });
    try std.testing.expectEqual(@as(u16, 202), (try commitGroupOf(&fx, idOf(one), &.{ .{ "pkg_a", m }, .{ "pkg_b", null }, .{ "pkg_c", m } })).status);
    try expectExists(try createOf(&fx, &.{try member(&fx, "pkg_a", "1.0.0", "1.1.0", "eleven again")}), try exists(&fx, "pkg_a", "1.0.0", "low"));
    const single = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.1.0", "eleven single");
    try expectExists(try commit(&fx, "pkg_a", "1.0.0", &.{single}, m), try exists(&fx, "pkg_a", "1.0.0", "low"));
    const single_c = try put(&fx, "pkg_c", "1.0.0", "linux-64", "1.1.0", "eleven single c");
    try expectExists(try commit(&fx, "pkg_c", "1.0.0", &.{single_c}, m), try exists(&fx, "pkg_c", "1.0.0", "low"));
    _ = try visible(&fx, idOf(one));

    // An open group's add that a single publish got to first is refused when the group commits, and the group stays open.
    const two = try createOf(&fx, &.{try member(&fx, "pkg_a", "1.0.0", "1.2.0", "twelve group")});
    try putAll(&fx, two, &.{"twelve group"});
    const racer = try put(&fx, "pkg_a", "1.0.0", "linux-64", "1.2.0", "twelve single");
    const done = try settle(&fx, try commit(&fx, "pkg_a", "1.0.0", &.{racer}, m));
    try std.testing.expectEqualStrings("published", done.value.object.get("status").?.string);
    try expectExists(try commitGroupOf(&fx, idOf(two), &.{.{ "pkg_a", m }}), try exists(&fx, "pkg_a", "1.0.0", "low"));
    try std.testing.expectEqualStrings("open", try fx.status(idOf(two)));
}

test "an add member's declared files stay listed after its group ended, and a rejected add leaves the version and frees the build" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const m = try fx.sha("manifest");
    try publishOne(&fx, "pkg_a", "1.0.0", "1.0.0", "low", m);

    const created = try createOf(&fx, &.{try member(&fx, "pkg_a", "1.0.0", "1.1.0", "eleven")});
    const aborted = try fx.call(.DELETE, try std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}", .{idOf(created)}), "", fx.alice_token);
    try std.testing.expectEqual(@as(u16, 200), aborted.status);
    const ended = try groupOf(&fx, idOf(created));
    try std.testing.expectEqualStrings("aborted", ended.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 1), ended.value.object.get("members").?.array.items[0].object.get("files").?.array.items.len);

    // A member whose bytes are rejected ends the group rejected; the version has no new file, and the build can be sent again.
    const bad = try createOf(&fx, &.{try member(&fx, "pkg_a", "1.0.0", "1.1.0", "REJECT:archive_invalid")});
    try putAll(&fx, bad, &.{"REJECT:archive_invalid"});
    try std.testing.expectEqual(@as(u16, 202), (try commitGroupOf(&fx, idOf(bad), &.{.{ "pkg_a", m }})).status);
    _ = try groupOf(&fx, idOf(bad));
    try std.testing.expectEqualStrings("rejected", (try groupOf(&fx, idOf(bad))).value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 1), (try getVersion(&fx, "/api/v1", "pkg_a", "1.0.0")).value.object.get("files").?.array.items.len);
    try std.testing.expectEqual(@as(u16, 201), (try createOf(&fx, &.{try member(&fx, "pkg_a", "1.0.0", "1.1.0", "eleven")})).status);
}

// ---------------------------------------------------------------------------
// What /api/v2 and the index show
// ---------------------------------------------------------------------------

fn bytesOf(nx: *Nx, token: []const u8, key: []const u8, version: []const u8, subdir: []const u8, compiler: []const u8, content: []const u8) ![]const u8 {
    const file = try nx.fmt("mojo-{s}-{s}-mojo{s}_0.conda", .{ "alice.json", version, compiler });
    const body = try nx.fmt("{{\"subdir\":\"{s}\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}", .{ subdir, file, try nx.sha(content), content.len });
    const begun = try nx.call(.POST, try nx.fmt("/api/v2/packages/{s}/{s}/files", .{ key, version }), body, token);
    try nt.expectStatus(begun, 200);
    const id = nt.str(begun.value, "upload_id");
    try nt.expectStatus(try nx.call(.PUT, try nx.fmt("/_fake/upload/{s}", .{id}), content, null), 200);
    return id;
}

fn commitV2(nx: *Nx, token: []const u8, version: []const u8, ids: []const []const u8, manifest: []const u8) !void {
    var list = std.ArrayList(u8).init(nx.life.allocator());
    for (ids, 0..) |id, i| try list.writer().print("{s}\"{s}\"", .{ if (i > 0) "," else "", id });
    const r = try nx.call(.POST, try nx.fmt("/api/v2/packages/alice/json/{s}/publish", .{version}), try nx.fmt("{{\"upload_ids\":[{s}],\"manifest_sha256\":\"{s}\"}}", .{ list.items, manifest }), token);
    try nt.expectStatus(r, 202);
    for (0..3) |_| try nt.expectStatus(try nx.call(.GET, nt.str(r.value, "status_url"), "", token), 200);
}

fn buildNames(nx: *Nx, list: []const Value) ![]const u8 {
    var out = std.ArrayList(u8).init(nx.life.allocator());
    for (list, 0..) |b, i| try out.writer().print("{s}{s}", .{ if (i > 0) " " else "", nt.str(b, "build") });
    return out.items;
}

test "index v2 lines and getVersion under /api/v2 list every build, sorted by compiler, beside the primary build's top-level fields" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    const token = try nx.apiToken(alice, "[\"publish\",\"yank\"]", "[\"alice/json\"]");
    try nt.expectStatus(try nx.call(.PUT, "/api/v2/packages/alice/json", "", token), 201);
    const m = try nx.sha("manifest");

    // 1.0.0 is published with two builds at once, and a third is added; 2.0.0 has one build.
    const high = try bytesOf(&nx, token, "alice/json", "1.0.0", "linux-64", "1.2.0", "high");
    const mid = try bytesOf(&nx, token, "alice/json", "1.0.0", "linux-64", "1.10.0", "mid");
    try commitV2(&nx, token, "1.0.0", &.{ high, mid }, m);
    const low = try bytesOf(&nx, token, "alice/json", "1.0.0", "osx-arm64", "1.0.0", "low");
    try commitV2(&nx, token, "1.0.0", &.{low}, m);
    const single = try bytesOf(&nx, token, "alice/json", "2.0.0", "linux-64", "1.1.0", "single");
    try commitV2(&nx, token, "2.0.0", &.{single}, m);

    const url = "http://fake.test/channel/alice/linux-64/";
    const record = try nx.file("index/v2/al/ic/alice/json");
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, record, "\n"), '\n');
    const first = try std.json.parseFromSliceLeaky(Value, nx.life.allocator(), lines.next().?, .{});
    try std.testing.expectEqualStrings("1.0.0", nt.str(first, "version"));
    try std.testing.expectEqual(@as(i64, 2), first.object.get("v").?.integer);
    // The top-level trio is the primary build's.
    try std.testing.expectEqualStrings("mojo1.0.0_0", nt.str(first, "build"));
    try std.testing.expectEqualStrings("==1.0.0", nt.str(first, "requires_mojo"));
    try std.testing.expectEqual(@as(usize, 1), first.object.get("files").?.array.items.len);
    try std.testing.expectEqualStrings("osx-arm64", nt.str(first.object.get("files").?.array.items[0], "subdir"));
    // `builds` has every build, numerically sorted (1.10.0 after 1.2.0), each with its own requirement and files.
    const all = first.object.get("builds").?.array.items;
    try std.testing.expectEqualStrings("mojo1.0.0_0 mojo1.2.0_0 mojo1.10.0_0", try buildNames(&nx, all));
    try std.testing.expectEqualStrings("==1.10.0", nt.str(all[2], "requires_mojo"));
    const mid_file = all[2].object.get("files").?.array.items[0];
    try std.testing.expectEqualStrings("mojo-alice.json-1.0.0-mojo1.10.0_0.conda", nt.str(mid_file, "filename"));
    try std.testing.expectEqualStrings(url ++ "mojo-alice.json-1.0.0-mojo1.10.0_0.conda", nt.str(mid_file, "url"));
    try std.testing.expectEqualStrings(try nx.sha("mid"), nt.str(mid_file, "sha256"));
    // A version with one build lists that one.
    const second = try std.json.parseFromSliceLeaky(Value, nx.life.allocator(), lines.next().?, .{});
    try std.testing.expectEqualStrings("mojo1.1.0_0", nt.str(second, "build"));
    try std.testing.expectEqualStrings("mojo1.1.0_0", try buildNames(&nx, second.object.get("builds").?.array.items));
    try std.testing.expectEqualStrings(nt.str(second.object.get("files").?.array.items[0], "filename"), nt.str(second.object.get("builds").?.array.items[0].object.get("files").?.array.items[0], "filename"));

    // getVersion: the primary build in `requires_mojo` and `files`, every build in `builds`.
    const v = try nx.call(.GET, "/api/v2/packages/alice/json/1.0.0", "", null);
    try nt.expectStatus(v, 200);
    try std.testing.expectEqualStrings("==1.0.0", nt.str(v.value, "requires_mojo"));
    try std.testing.expectEqual(@as(usize, 1), v.value.object.get("files").?.array.items.len);
    try std.testing.expectEqualStrings("mojo1.0.0_0 mojo1.2.0_0 mojo1.10.0_0", try buildNames(&nx, v.value.object.get("builds").?.array.items));
    try std.testing.expectEqualStrings(url ++ "mojo-alice.json-1.0.0-mojo1.2.0_0.conda", nt.str(v.value.object.get("builds").?.array.items[1].object.get("files").?.array.items[0], "url"));

    // The repodata of the namespace's channel lists every file of both versions, each with its own build and compiler.
    const repodata = try nx.call(.GET, "/channel/alice/linux-64/repodata.json", "", null);
    const entries = repodata.value.object.get("packages.conda").?.object;
    try std.testing.expectEqual(@as(usize, 3), entries.count());
    try std.testing.expectEqualStrings("mojo-compiler ==1.10.0", entries.get("mojo-alice.json-1.0.0-mojo1.10.0_0.conda").?.object.get("depends").?.array.items[0].string);
    try std.testing.expectEqualStrings("mojo1.2.0_0", nt.str(entries.get("mojo-alice.json-1.0.0-mojo1.2.0_0.conda").?, "build"));
    try std.testing.expectEqual(@as(usize, 1), (try nx.call(.GET, "/channel/alice/osx-arm64/repodata.json", "", null)).value.object.get("packages.conda").?.object.count());

    // Taken down: every build keeps its sha256 and loses its URL, in the index and in getVersion.
    try nx.control("/_fake/tombstone", "{\"name\":\"alice/json\",\"version\":\"1.0.0\",\"reason_code\":\"malware\"}");
    const gone = try nx.call(.GET, "/api/v2/packages/alice/json/1.0.0", "", null);
    try std.testing.expectEqualStrings("tombstoned", nt.str(gone.value, "state"));
    try std.testing.expect(gone.value.object.get("files").?.array.items[0].object.get("url") == null);
    for (gone.value.object.get("builds").?.array.items) |b| {
        const f = b.object.get("files").?.array.items[0];
        try std.testing.expect(f.object.get("url") == null);
        try std.testing.expectEqual(@as(usize, 64), nt.str(f, "sha256").len);
    }
    try std.testing.expectEqualStrings("mojo1.0.0_0 mojo1.2.0_0 mojo1.10.0_0", try buildNames(&nx, gone.value.object.get("builds").?.array.items));
    var after_lines = std.mem.splitScalar(u8, try nx.file("index/v2/al/ic/alice/json"), '\n');
    const tomb_line = after_lines.next().?;
    const tomb = try std.json.parseFromSliceLeaky(Value, nx.life.allocator(), tomb_line, .{});
    try std.testing.expectEqual(@as(usize, 3), tomb.object.get("builds").?.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, tomb_line, "\"url\"") == null);
}
