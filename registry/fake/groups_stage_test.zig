//! Unit tests of the `stage` token scope in the fake (the executable spec of the hosted registry): what a token that may only stage can
//! and cannot do, and what the `purpose` of a CI exchange mints. Each test sends requests through `api.handle` and reads the answers as a
//! client would; the fixture is groups_test.zig's.

const std = @import("std");
const t = @import("groups_test.zig");
const st = @import("state.zig");
const Fx = t.Fx;
const Reply = t.Reply;
const abc = t.abc;
const idOf = t.idOf;
const expectCode = t.expectCode;

/// A token of alice's with exactly `scopes` for pkg_a, pkg_b and pkg_c.
fn tokenWith(fx: *Fx, id: []const u8, scopes: []const st.Scope) ![]const u8 {
    const s = &fx.state;
    const all: []const []const u8 = &.{ "pkg_a", "pkg_b", "pkg_c" };
    return (try s.addToken(.{ .id = id, .secret = id, .kind = .api, .user = fx.alice, .scopes = scopes, .packages = all, .created_at = s.now(), .expires_at = s.now() + st.day })).secret;
}

fn groupPath(fx: *Fx, id: []const u8, tail: []const u8) ![]const u8 {
    return std.fmt.allocPrint(fx.life.allocator(), "/api/v1/groups/{s}{s}", .{ id, tail });
}

fn statusOf(fx: *Fx, id: []const u8) ![]const u8 {
    return (try fx.call(.GET, try groupPath(fx, id, ""), "", fx.alice_token)).value.object.get("status").?.string;
}

/// Polls until the group is visible: the fake moves a committed group one stage per read.
fn untilVisible(fx: *Fx, id: []const u8) !void {
    for (0..6) |_| {
        if (std.mem.eql(u8, try statusOf(fx, id), "visible")) return;
    }
    return error.TestUnexpectedResult;
}

test "a stage token creates, reads and aborts a group, as a publish token does" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const stage = try tokenWith(&fx, "stage1", &.{.stage});

    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), stage);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    const id = idOf(created);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.GET, try groupPath(&fx, id, ""), "", stage)).status);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.DELETE, try groupPath(&fx, id, ""), "", stage)).status);
    try std.testing.expectEqualStrings("aborted", try statusOf(&fx, id));

    // a publish token reads and aborts a group a stage token made
    const again = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.1", "x"), stage);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.GET, try groupPath(&fx, idOf(again), ""), "", fx.alice_token)).status);
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.DELETE, try groupPath(&fx, idOf(again), ""), "", fx.alice_token)).status);
}

test "a stage token cannot commit a group, publish a single version or yank, and the group is left as it was" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const stage = try tokenWith(&fx, "stage1", &.{.stage});
    const both = try tokenWith(&fx, "stage2", &.{ .stage, .yank });

    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), stage);
    const id = idOf(created);
    try fx.upload(created, "x");
    const commit = try groupPath(&fx, id, "/commit");
    try expectCode(try fx.call(.POST, commit, try fx.commitBody(abc), stage), 403, "scope_missing");
    try expectCode(try fx.call(.POST, commit, try fx.commitBody(abc), both), 403, "scope_missing");
    try std.testing.expectEqualStrings("open", try statusOf(&fx, id));
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, try fx.commitBody(abc), fx.alice_token)).status);
    try untilVisible(&fx, id);

    // a single publish: begin and commit
    try expectCode(try fx.call(.POST, "/api/v1/packages/pkg_b/2.0.0/files", "{}", stage), 403, "scope_missing");
    try expectCode(try fx.call(.POST, "/api/v1/packages/pkg_b/2.0.0/publish", "{}", stage), 403, "scope_missing");

    // a yank, of a group and of a version
    const body = "{\"yanked\":true,\"reason\":\"broken\"}";
    try expectCode(try fx.call(.PUT, try groupPath(&fx, id, "/yank"), body, stage), 403, "scope_missing");
    try expectCode(try fx.call(.PUT, "/api/v1/packages/pkg_b/1.0.0/yank", body, stage), 403, "scope_missing");
    try std.testing.expectEqualStrings("visible", try statusOf(&fx, id));
    const v = try fx.call(.GET, "/api/v1/packages/pkg_b/1.0.0", "", null);
    try std.testing.expectEqualStrings("published", v.value.object.get("state").?.string);

    // `stage` beside `yank` takes nothing from `yank`
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.PUT, "/api/v1/packages/pkg_b/1.0.0/yank", body, both)).status);
}

test "a stage token reserves only what its list names and its owner owns" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const s = &fx.state;
    // bob owns pkg_a only; his stage token names pkg_a and pkg_b
    const bob = (try s.addToken(.{ .id = "bobstage", .secret = "bobstage", .kind = .api, .user = fx.bob, .scopes = &.{.stage}, .packages = &.{ "pkg_a", "pkg_b" }, .created_at = s.now(), .expires_at = s.now() + st.day })).secret;
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(&.{ "pkg_a", "pkg_c" }, "1.0.0", "x"), bob), 403, "scope_missing");
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(&.{ "pkg_a", "pkg_b" }, "1.0.0", "x"), bob), 403, "not_owner");
    try std.testing.expectEqual(@as(usize, 0), s.groups.items.len);
    try std.testing.expectEqual(@as(u16, 201), (try fx.call(.POST, "/api/v1/groups", try fx.request(&.{"pkg_a"}, "1.0.0", "x"), bob)).status);
}

test "a stage-only token cannot claim a package and nothing is reserved; with yank or publish it can" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const stage = try tokenWith(&fx, "stage1", &.{.stage});
    const before = fx.state.packages.items.len;
    try expectCode(try fx.call(.POST, "/api/v1/packages/fresh_one/claim", "", stage), 403, "scope_missing");
    try std.testing.expectEqual(before, fx.state.packages.items.len);
    const both = try tokenWith(&fx, "stage2", &.{ .stage, .yank });
    try std.testing.expectEqual(@as(u16, 201), (try fx.call(.POST, "/api/v1/packages/fresh_one/claim", "", both)).status);
    const pub_token = try tokenWith(&fx, "pub1", &.{.publish});
    try std.testing.expectEqual(@as(u16, 201), (try fx.call(.POST, "/api/v1/packages/fresh_two/claim", "", pub_token)).status);
}

test "a token with yank alone may not create, read or abort a group" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const yank = try tokenWith(&fx, "yank1", &.{.yank});
    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.0", "x"), fx.alice_token);
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(abc, "1.0.1", "x"), yank), 403, "scope_missing");
    try expectCode(try fx.call(.GET, try groupPath(&fx, idOf(created), ""), "", yank), 403, "scope_missing");
    try expectCode(try fx.call(.DELETE, try groupPath(&fx, idOf(created), ""), "", yank), 403, "scope_missing");
}

test "a stage token is accepted as a token scope, listed as made, and an unknown scope is still refused" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    const made = try fx.call(.POST, "/api/v1/me/tokens", "{\"name\":\"s\",\"scopes\":[\"stage\"],\"packages\":[\"pkg_a\"],\"expires_in_days\":1}", fx.session);
    try std.testing.expectEqual(@as(u16, 201), made.status);
    try std.testing.expectEqualStrings("stage", made.value.object.get("scopes").?.array.items[0].string);
    try expectCode(try fx.call(.POST, "/api/v1/me/tokens", "{\"name\":\"s\",\"scopes\":[\"owners\"],\"packages\":[\"pkg_a\"],\"expires_in_days\":1}", fx.session), 400, "invalid_request");
}

fn jwtOf(fx: *Fx, repository: []const u8) ![]const u8 {
    const a = fx.life.allocator();
    const enc = std.base64.url_safe_no_pad.Encoder;
    const payload = try std.fmt.allocPrint(a, "{{\"repository\":\"{s}\"}}", .{repository});
    const part = try a.alloc(u8, enc.calcSize(payload.len));
    _ = enc.encode(part, payload);
    return std.fmt.allocPrint(a, "e30.{s}.c2ln", .{part});
}

fn exchange(fx: *Fx, extra: []const u8) !Reply {
    const jwt = try jwtOf(fx, "org/repo");
    const body = try std.fmt.allocPrint(fx.life.allocator(), "{{\"jwt\":\"{s}\",\"packages\":[{{\"name\":\"new_one\",\"version\":\"1.0.0\"}}]{s}}}", .{ jwt, extra });
    return fx.call(.POST, "/api/v1/auth/oidc/exchange", body, null);
}

test "the exchange purpose: stage mints a stage-only token, the default and publish mint the publish token, anything else is refused" {
    var fx: Fx = undefined;
    try fx.setup();
    defer fx.deinit();
    try fx.state.ci_repos.append(fx.life.allocator(), "org/repo");
    const names: []const []const u8 = &.{"new_one"};

    const refused = [_][]const u8{ ",\"purpose\":\"admin\"", ",\"purpose\":5", ",\"purpose\":null", ",\"purpose\":\"\"" };
    for (refused) |extra| try expectCode(try exchange(&fx, extra), 400, "invalid_request");
    // the single-package form refuses it too, before the token is looked at
    const single = try std.fmt.allocPrint(fx.life.allocator(), "{{\"jwt\":\"{s}\",\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"purpose\":\"admin\"}}", .{try jwtOf(&fx, "org/repo")});
    try expectCode(try fx.call(.POST, "/api/v1/auth/oidc/exchange", single, null), 400, "invalid_request");
    try std.testing.expect(fx.state.packageByName("new_one") == null);
    try std.testing.expectEqual(@as(usize, 3), fx.state.tokens.items.len);

    const published = try exchange(&fx, "");
    try std.testing.expectEqualStrings("publish", published.value.object.get("token_kind").?.string);
    const explicit = try exchange(&fx, ",\"purpose\":\"publish\"");
    try std.testing.expectEqualStrings("publish", explicit.value.object.get("token_kind").?.string);

    const minted = try exchange(&fx, ",\"purpose\":\"stage\"");
    try std.testing.expectEqual(@as(u16, 200), minted.status);
    try std.testing.expectEqualStrings("stage", minted.value.object.get("token_kind").?.string);
    const stage = minted.value.object.get("token").?.string;

    const created = try fx.call(.POST, "/api/v1/groups", try fx.request(names, "1.0.0", "x"), stage);
    try std.testing.expectEqual(@as(u16, 201), created.status);
    const id = idOf(created);
    // pinned like the publish token: not another version, not another package
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(names, "2.0.0", "x"), stage), 403, "scope_missing");
    try expectCode(try fx.call(.POST, "/api/v1/groups", try fx.request(&.{ "new_one", "pkg_a" }, "1.0.0", "x"), stage), 403, "scope_missing");
    try std.testing.expectEqual(@as(u16, 200), (try fx.call(.GET, try groupPath(&fx, id, ""), "", stage)).status);
    try fx.upload(created, "x");
    const commit = try groupPath(&fx, id, "/commit");
    const body = try fx.commitBody(names);
    try expectCode(try fx.call(.POST, commit, body, stage), 403, "scope_missing");
    try std.testing.expectEqualStrings("open", (try fx.call(.GET, try groupPath(&fx, id, ""), "", stage)).value.object.get("status").?.string);

    // the publish token of the same exchange commits it
    const publish = published.value.object.get("token").?.string;
    try std.testing.expectEqual(@as(u16, 202), (try fx.call(.POST, commit, body, publish)).status);
}
