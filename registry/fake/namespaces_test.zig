//! Unit tests of `/api/v2` and owner namespaces (namespaces.zig, keys.zig, the namespace parts of state.zig), by
//! behaviour: each test sends requests through `api.handle`, as the server does, with no socket, and reads the answers as
//! a client would. namespaces_publish_test.zig holds the publishing tests and the files they write.

const std = @import("std");
const Value = std.json.Value;
const api = @import("api.zig");
const st = @import("state.zig");

pub const Reply = struct { status: u16, body: []const u8, value: Value };

pub const Nx = struct {
    tmp: std.testing.TmpDir,
    life: std.heap.ArenaAllocator,
    state: st.State,

    pub fn setup(nx: *Nx) !void {
        nx.tmp = std.testing.tmpDir(.{});
        nx.life = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = nx.life.allocator();
        const dir = try nx.tmp.dir.realpathAlloc(a, ".");
        nx.state = .{ .alloc = a, .base_url = "http://fake.test", .stage = "beta", .dir = dir };
        try @import("files.zig").rewrite(a, &nx.state);
    }

    pub fn deinit(nx: *Nx) void {
        nx.life.deinit();
        nx.tmp.cleanup();
    }

    pub fn fmt(nx: *Nx, comptime f: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(nx.life.allocator(), f, args);
    }

    /// One request, as the server serves it: `target` may carry a query string; everything the handler is given lives
    /// in an arena freed after the answer.
    pub fn call(nx: *Nx, method: std.http.Method, target: []const u8, body: []const u8, token: ?[]const u8) !Reply {
        const life = nx.life.allocator();
        var request_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer request_arena.deinit();
        const a = request_arena.allocator();
        const t = try a.dupe(u8, target);
        const q = std.mem.indexOfScalar(u8, t, '?');
        var ctx = api.Ctx{
            .arena = a,
            .state = &nx.state,
            .method = method,
            .path = if (q) |n| t[0..n] else t,
            .query = if (q) |n| t[n + 1 ..] else "",
            .body = try a.dupe(u8, body),
            .authorization = if (token) |x| try std.fmt.allocPrint(a, "Bearer {s}", .{x}) else null,
        };
        const r = try api.handle(&ctx);
        const kept = try life.dupe(u8, r.body);
        const value = std.json.parseFromSliceLeaky(Value, life, kept, .{}) catch Value{ .null = {} };
        return .{ .status = @intFromEnum(r.status), .body = kept, .value = value };
    }

    /// A session of `handle`, as a login gives (the login makes its user namespace when free).
    pub fn session(nx: *Nx, handle: []const u8) ![]const u8 {
        const r = try nx.call(.POST, "/_fake/session", try nx.fmt("{{\"handle\":\"{s}\"}}", .{handle}), null);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        return r.value.object.get("token").?.string;
    }

    pub fn control(nx: *Nx, path: []const u8, body: []const u8) !void {
        const r = try nx.call(.POST, path, body, null);
        if (r.status != 200) {
            std.debug.print("{s}: {s}\n", .{ path, r.body });
            return error.TestUnexpectedResult;
        }
    }

    /// An API token of the account `session` belongs to, with `scopes` (JSON) for `packages` (JSON), made under v2.
    pub fn apiToken(nx: *Nx, session_token: []const u8, scopes: []const u8, packages: []const u8) ![]const u8 {
        const body = try nx.fmt("{{\"name\":\"t\",\"scopes\":{s},\"packages\":{s},\"expires_in_days\":7}}", .{ scopes, packages });
        const r = try nx.call(.POST, "/api/v2/me/tokens", body, session_token);
        try expectStatus(r, 201);
        return r.value.object.get("token").?.string;
    }

    /// The file `rel` under the data directory.
    pub fn file(nx: *Nx, rel: []const u8) ![]const u8 {
        return nx.tmp.dir.readFileAlloc(nx.life.allocator(), rel, 1 << 20);
    }

    pub fn sha(nx: *Nx, bytes: []const u8) ![]const u8 {
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
        return nx.fmt("{s}", .{std.fmt.fmtSliceHexLower(&d)});
    }
};

pub fn expectStatus(r: Reply, status: u16) !void {
    if (r.status != status) {
        std.debug.print("want {d}, got {d}: {s}\n", .{ status, r.status, r.body });
        return error.TestUnexpectedResult;
    }
}

pub fn expectCode(r: Reply, status: u16, want: []const u8) !void {
    const got = if (r.value == .object) if (r.value.object.get("error")) |e| e.object.get("code").?.string else "" else "";
    if (r.status != status or !std.mem.eql(u8, got, want)) {
        std.debug.print("want {d} {s}, got {d}: {s}\n", .{ status, want, r.status, r.body });
        return error.TestUnexpectedResult;
    }
}

pub fn str(v: Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

/// The `namespaces` of a `GET /api/v2/me` answer as `<namespace>:<kind>:<role>:<packages, comma-separated>` lines.
fn namespacesOf(nx: *Nx, token: []const u8) ![]const u8 {
    const r = try nx.call(.GET, "/api/v2/me", "", token);
    try expectStatus(r, 200);
    var out = std.ArrayList(u8).init(nx.life.allocator());
    for (r.value.object.get("namespaces").?.array.items) |n| {
        try out.writer().print("{s}:{s}:{s}:", .{ str(n, "namespace"), str(n, "kind"), str(n, "role") });
        for (n.object.get("packages").?.array.items, 0..) |p, i| {
            if (i > 0) try out.append(',');
            try out.appendSlice(p.string);
        }
        try out.append('\n');
    }
    return out.items;
}

fn unavailableOf(nx: *Nx, token: []const u8) !?[]const u8 {
    const r = try nx.call(.GET, "/api/v2/me", "", token);
    try expectStatus(r, 200);
    const v = r.value.object.get("unavailable_namespace") orelse return null;
    return v.string;
}

test "a login makes the user namespace of the lower-cased login; /api/v2/me lists it with its packages" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("Alice-X");
    try std.testing.expectEqualStrings("alice-x:user:owner:\n", try namespacesOf(&nx, alice));
    try std.testing.expect(try unavailableOf(&nx, alice) == null);
    const made = try nx.call(.PUT, "/api/v2/packages/alice-x/json", "", alice);
    try expectStatus(made, 201);
    try std.testing.expectEqualStrings("alice-x:user:owner:alice-x/json\n", try namespacesOf(&nx, alice));
    // v1's caller lists v1 packages only: a package in a namespace has no owners there.
    const me1 = try nx.call(.GET, "/api/v1/me", "", alice);
    try expectStatus(me1, 200);
    try std.testing.expectEqual(@as(usize, 0), me1.value.object.get("packages").?.array.items.len);
    const ns = try nx.call(.GET, "/api/v2/namespaces/alice-x", "", null);
    try expectStatus(ns, 200);
    try std.testing.expectEqualStrings("user", str(ns.value, "kind"));
    try std.testing.expectEqualStrings("Alice-X", str(ns.value, "login"));
    try std.testing.expect(!ns.value.object.get("frozen").?.bool);
}

test "a login outside the grammar, reserved, or held by another account gets no namespace, and /me says which login" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    for ([_][]const u8{ "enterprise_login", "linux-64", "noarch", "index", "native-mirror", "a" ** 40 }) |h| {
        const t = try nx.session(h);
        try std.testing.expectEqualStrings("", try namespacesOf(&nx, t));
        try std.testing.expectEqualStrings(h, (try unavailableOf(&nx, t)).?);
    }
    try std.testing.expect(nx.state.namespaceByName("linux-64") == null);

    // A rename keeps the old namespace and gains the new one at the next login; whoever takes the old login gets none.
    _ = try nx.session("alice");
    try nx.control("/_fake/rename", "{\"login\":\"alice\",\"to\":\"alice2\"}");
    const renamed = try nx.session("alice2");
    try std.testing.expectEqualStrings("alice:user:owner:\nalice2:user:owner:\n", try namespacesOf(&nx, renamed));
    try std.testing.expect(try unavailableOf(&nx, renamed) == null);
    const stranger = try nx.session("alice");
    try std.testing.expectEqualStrings("", try namespacesOf(&nx, stranger));
    try std.testing.expectEqualStrings("alice", (try unavailableOf(&nx, stranger)).?);
    try expectCode(try nx.call(.PUT, "/api/v2/packages/alice/json", "", stranger), 403, "not_namespace_member");
    const info = try nx.call(.GET, "/api/v2/namespaces/alice", "", null);
    try std.testing.expectEqualStrings("alice2", str(info.value, "login"));
}

test "PUT creates a package in a namespace the caller can write: 201, then 200; each refusal by its error" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    const bob = try nx.session("bob");
    const made = try nx.call(.PUT, "/api/v2/packages/alice/json", "", alice);
    try expectStatus(made, 201);
    try std.testing.expectEqualStrings("alice/json", str(made.value, "name"));
    try std.testing.expectEqualStrings("alice", str(made.value.object.get("namespace").?, "namespace"));
    try std.testing.expect(made.value.object.get("owners") == null);
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/alice/json", "", alice), 200);
    // The right is checked before the answer, also for a package that exists.
    try expectCode(try nx.call(.PUT, "/api/v2/packages/alice/json", "", bob), 403, "not_namespace_member");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/alice/yaml", "", bob), 403, "not_namespace_member");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/alice/yaml", "", null), 401, "token_missing");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/nobody/json", "", alice), 404, "namespace_not_found");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/Alice/json", "", alice), 400, "invalid_namespace");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/al_ice/json", "", alice), 400, "invalid_namespace");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/alice/Json", "", alice), 400, "invalid_name");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/alice/my-json", "", alice), 400, "invalid_name");
    for ([_][]const u8{ "std", "mojo", "max", "stdlib", "fn", "struct", "len", "print" }) |n| {
        try expectCode(try nx.call(.PUT, try nx.fmt("/api/v2/packages/alice/{s}", .{n}), "", alice), 403, "name_reserved");
    }
    // A namespace with no name, a deeper path, and the v1 routes v2 dropped are not routes.
    try expectCode(try nx.call(.PUT, "/api/v2/packages/alice", "", alice), 404, "route_not_found");
    try expectCode(try nx.call(.POST, "/api/v2/packages/alice/json/claim", "", alice), 404, "route_not_found");
    try expectCode(try nx.call(.GET, "/api/v2/packages/alice/json/owners", "", alice), 404, "route_not_found");
    try expectCode(try nx.call(.GET, "/api/v2/me/invitations", "", alice), 404, "route_not_found");

    const got = try nx.call(.GET, "/api/v2/packages/alice/json", "", null);
    try expectStatus(got, 200);
    try std.testing.expectEqualStrings("alice/json", str(got.value, "name"));
    try std.testing.expectEqualStrings("claimed", str(got.value, "state"));
    try expectCode(try nx.call(.GET, "/api/v2/packages/alice/yaml", "", null), 404, "package_not_found");
    try expectCode(try nx.call(.GET, "/api/v2/packages/carol/yaml", "", null), 404, "namespace_not_found");
    try expectStatus(try nx.call(.GET, "/api/v2/packages/alice/json/versions", "", null), 200);
    // The two prefixes never see each other's packages.
    try expectCode(try nx.call(.GET, "/api/v1/packages/json", "", null), 404, "package_not_found");
    try expectCode(try nx.call(.GET, "/api/v2/namespaces/nobody", "", null), 404, "namespace_not_found");
    try expectCode(try nx.call(.GET, "/api/v2/namespaces/No-Body", "", null), 400, "invalid_namespace");
}

test "an organization namespace: created by an active admin with the App installed, written by active members only" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    const bob = try nx.session("bob");
    const carol = try nx.session("carol");
    const dave = try nx.session("dave");
    const body = "{\"namespace\":\"komira-ai\"}";
    // No such organization, then one without the App.
    try expectCode(try nx.call(.POST, "/api/v2/namespaces", body, alice), 403, "namespace_unverified");
    try nx.control("/_fake/org", "{\"login\":\"komira-ai\",\"members\":[{\"handle\":\"alice\",\"role\":\"admin\"},{\"handle\":\"bob\",\"role\":\"member\"},{\"handle\":\"carol\",\"role\":\"member\",\"state\":\"pending\"},{\"handle\":\"dave\",\"role\":\"billing_manager\"}]}");
    const no_app = try nx.call(.POST, "/api/v2/namespaces", body, alice);
    try expectCode(no_app, 403, "namespace_unverified");
    try std.testing.expectEqualStrings("'komira-ai' cannot be verified on GitHub: the mopm registry GitHub App is not installed on the organization.", str(no_app.value.object.get("error").?, "message"));
    try nx.control("/_fake/org", "{\"login\":\"komira-ai\",\"installed\":true}");
    // A pending admin and a non-member may not create it either.
    _ = try nx.session("erin");
    try nx.control("/_fake/org", "{\"login\":\"komira-ai\",\"members\":[{\"handle\":\"alice\",\"role\":\"admin\"},{\"handle\":\"bob\",\"role\":\"member\"},{\"handle\":\"carol\",\"role\":\"admin\",\"state\":\"pending\"},{\"handle\":\"dave\",\"role\":\"billing_manager\"}]}");
    try expectCode(try nx.call(.POST, "/api/v2/namespaces", body, carol), 403, "not_namespace_member");
    try expectCode(try nx.call(.POST, "/api/v2/namespaces", body, try nx.session("erin")), 403, "not_namespace_member");
    // A member who is not an admin may not create it; a stale session may not either; reserved and bad names are refused.
    try expectCode(try nx.call(.POST, "/api/v2/namespaces", body, bob), 403, "not_namespace_member");
    const stale = try nx.call(.POST, "/_fake/session", "{\"handle\":\"alice\",\"fresh\":false}", null);
    try expectCode(try nx.call(.POST, "/api/v2/namespaces", body, str(stale.value, "token")), 401, "stale_session");
    try expectCode(try nx.call(.POST, "/api/v2/namespaces", "{\"namespace\":\"linux-64\"}", alice), 403, "namespace_reserved");
    try expectCode(try nx.call(.POST, "/api/v2/namespaces", "{\"namespace\":\"Komira-AI\"}", alice), 400, "invalid_namespace");
    try expectCode(try nx.call(.POST, "/api/v2/namespaces", "{}", alice), 400, "invalid_request");

    const made = try nx.call(.POST, "/api/v2/namespaces", body, alice);
    try expectStatus(made, 201);
    try std.testing.expectEqualStrings("org", str(made.value, "kind"));
    try std.testing.expectEqualStrings("komira-ai", str(made.value, "login"));
    try std.testing.expectEqualStrings("alice:user:owner:\nkomira-ai:org:admin:\n", try namespacesOf(&nx, alice));

    // Active admins and members write; pending and billing managers do not, and are not listed by /me.
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/komira-ai/json", "", bob), 201);
    try expectCode(try nx.call(.PUT, "/api/v2/packages/komira-ai/yaml", "", carol), 403, "not_namespace_member");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/komira-ai/yaml", "", dave), 403, "not_namespace_member");
    try std.testing.expectEqualStrings("bob:user:owner:\nkomira-ai:org:member:komira-ai/json\n", try namespacesOf(&nx, bob));
    try std.testing.expectEqualStrings("carol:user:owner:\n", try namespacesOf(&nx, carol));

    // A token is checked when it is used: removed from the organization, bob's token stops working.
    const bob_token = try nx.apiToken(bob, "[\"publish\"]", "[\"komira-ai/json\"]");
    try nx.control("/_fake/org", "{\"login\":\"komira-ai\",\"members\":[{\"handle\":\"alice\",\"role\":\"admin\"}]}");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/komira-ai/json", "", bob_token), 403, "not_namespace_member");

    // The organization renamed keeps writing; its namespace keeps its name and shows the new login.
    try nx.control("/_fake/rename", "{\"login\":\"komira-ai\",\"to\":\"komira\"}");
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/komira-ai/yaml", "", alice), 201);
    try std.testing.expectEqualStrings("komira", str((try nx.call(.GET, "/api/v2/namespaces/komira-ai", "", null)).value, "login"));
    try nx.control("/_fake/rename", "{\"login\":\"komira\",\"to\":\"komira-ai\"}");

    // The App uninstalled: the namespace is frozen, reads work, writes are refused; installing it again is not enough until
    // an admin binds the new installation.
    try nx.control("/_fake/org", "{\"login\":\"komira-ai\",\"installed\":false}");
    const frozen = try nx.call(.GET, "/api/v2/namespaces/komira-ai", "", null);
    try std.testing.expect(frozen.value.object.get("frozen").?.bool);
    try expectStatus(try nx.call(.GET, "/api/v2/packages/komira-ai/json", "", null), 200);
    const refused = try nx.call(.PUT, "/api/v2/packages/komira-ai/toml", "", alice);
    try expectCode(refused, 403, "namespace_unverified");
    try std.testing.expectEqualStrings("'komira-ai' cannot be verified on GitHub: no installation of the mopm registry GitHub App is bound to it.", str(refused.value.object.get("error").?, "message"));
    try std.testing.expect(std.mem.indexOf(u8, try namespacesOf(&nx, alice), "komira-ai") == null);
    try nx.control("/_fake/org", "{\"login\":\"komira-ai\",\"installed\":true}");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/komira-ai/toml", "", alice), 403, "namespace_unverified");
    const again = try nx.call(.POST, "/api/v2/namespaces", body, alice);
    try expectStatus(again, 200);
    try std.testing.expect(!again.value.object.get("frozen").?.bool);
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/komira-ai/toml", "", alice), 201);
}

test "an organization that takes a login another account's namespace holds is refused that namespace" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    _ = try nx.session("zed");
    try nx.control("/_fake/rename", "{\"login\":\"zed\",\"to\":\"zed2\"}");
    try nx.control("/_fake/org", "{\"login\":\"zed\",\"installed\":true,\"members\":[{\"handle\":\"alice\",\"role\":\"admin\"}]}");
    const r = try nx.call(.POST, "/api/v2/namespaces", "{\"namespace\":\"zed\"}", alice);
    try expectCode(r, 403, "namespace_unverified");
    try std.testing.expectEqualStrings("'zed' cannot be verified on GitHub: it belongs to another GitHub account.", str(r.value.object.get("error").?, "message"));
    try std.testing.expectEqualStrings("user", str((try nx.call(.GET, "/api/v2/namespaces/zed", "", null)).value, "kind"));
}

test "v2 API tokens name full names in namespaces the caller can write, created or not" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    _ = try nx.session("bob");
    const t = try nx.apiToken(alice, "[\"publish\"]", "[\"alice/json\"]");
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/alice/json", "", t), 201);
    // The token names one package: another is scope_missing; a token without publish may not create.
    try expectCode(try nx.call(.PUT, "/api/v2/packages/alice/yaml", "", t), 403, "scope_missing");
    const yank_only = try nx.apiToken(alice, "[\"yank\"]", "[\"alice/yaml\"]");
    try expectCode(try nx.call(.PUT, "/api/v2/packages/alice/yaml", "", yank_only), 403, "scope_missing");
    const body = "{{\"name\":\"t\",\"scopes\":[\"publish\"],\"packages\":{s},\"expires_in_days\":7}}";
    try expectCode(try nx.call(.POST, "/api/v2/me/tokens", try nx.fmt(body, .{"[\"bob/json\"]"}), alice), 403, "not_namespace_member");
    try expectCode(try nx.call(.POST, "/api/v2/me/tokens", try nx.fmt(body, .{"[\"ghost/json\"]"}), alice), 404, "namespace_not_found");
    try expectCode(try nx.call(.POST, "/api/v2/me/tokens", try nx.fmt(body, .{"[\"json\"]"}), alice), 400, "invalid_name");
    try expectCode(try nx.call(.POST, "/api/v2/me/tokens", try nx.fmt(body, .{"[\"Alice/json\"]"}), alice), 400, "invalid_namespace");
    // v1 tokens keep v1 names.
    try expectCode(try nx.call(.POST, "/api/v1/me/tokens", try nx.fmt(body, .{"[\"alice/json\"]"}), alice), 400, "invalid_name");
    // all_current under v2 is the packages of the namespaces the caller can write now.
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/alice/yaml", "", alice), 201);
    const all = try nx.call(.POST, "/api/v2/me/tokens", try nx.fmt(body, .{"\"all_current\""}), alice);
    try expectStatus(all, 201);
    const listed = all.value.object.get("packages").?;
    try std.testing.expectEqualStrings("all_current", listed.string);
    const tok = nx.state.tokenBySecret(str(all.value, "token")).?;
    try std.testing.expectEqual(@as(usize, 2), tok.packages.len);
    try std.testing.expectEqualStrings("alice/json", tok.packages[0]);
    try std.testing.expectEqualStrings("alice/yaml", tok.packages[1]);
}

test "search under v2: a name prefix in every namespace, or one namespace; v1 lists v1 packages only" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    const bob = try nx.session("bob");
    for ([_][]const u8{ "/api/v2/packages/alice/json", "/api/v2/packages/alice/yaml" }) |p| try expectStatus(try nx.call(.PUT, p, "", alice), 201);
    try expectStatus(try nx.call(.PUT, "/api/v2/packages/bob/json_x", "", bob), 201);
    try expectStatus(try nx.call(.POST, "/api/v1/packages/json_flat/claim", "", alice), 201);
    const cases = [_]struct { q: []const u8, want: []const u8 }{
        .{ .q = "/api/v2/packages?q=json", .want = "alice/json,bob/json_x," },
        .{ .q = "/api/v2/packages?q=alice/", .want = "alice/json,alice/yaml," },
        .{ .q = "/api/v2/packages?q=alice%2Fj", .want = "alice/json," },
        .{ .q = "/api/v2/packages?q=bob%2f", .want = "bob/json_x," },
        .{ .q = "/api/v2/packages?q=carol/", .want = "" },
        .{ .q = "/api/v2/packages", .want = "alice/json,alice/yaml,bob/json_x," },
        .{ .q = "/api/v1/packages?q=json", .want = "json_flat," },
        .{ .q = "/api/v1/packages", .want = "json_flat," },
    };
    for (cases) |c| {
        const r = try nx.call(.GET, c.q, "", null);
        try expectStatus(r, 200);
        var got = std.ArrayList(u8).init(nx.life.allocator());
        for (r.value.object.get("packages").?.array.items) |p| try got.writer().print("{s},", .{str(p, "name")});
        std.testing.expectEqualStrings(c.want, got.items) catch |e| {
            std.debug.print("query {s}\n", .{c.q});
            return e;
        };
    }
    try expectCode(try nx.call(.GET, "/api/v2/packages?q=Alice/", "", null), 400, "invalid_namespace");
    try expectCode(try nx.call(.GET, "/api/v2/packages?q=/json", "", null), 400, "invalid_namespace");
}

test "with v1 creation off, a claim and the OIDC packages form for a new name answer name_reserved with the update hint" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const alice = try nx.session("alice");
    try expectStatus(try nx.call(.POST, "/api/v1/packages/old_name/claim", "", alice), 201);
    try nx.control("/_fake/v1_creation", "{\"enabled\":false}");
    const r = try nx.call(.POST, "/api/v1/packages/new_name/claim", "", alice);
    try expectCode(r, 403, "name_reserved");
    try std.testing.expectEqualStrings("package names are in namespaces now; update mopm", str(r.value.object.get("error").?, "hint"));
    try std.testing.expectEqualStrings("'new_name' is reserved.", str(r.value.object.get("error").?, "message"));
    // A name that exists is still that package's.
    try expectCode(try nx.call(.POST, "/api/v1/packages/old_name/claim", "", alice), 409, "name_taken");
    // The packages form: a CI publisher of the deployment may still publish a name it has, not make one.
    try nx.control("/_fake/ci_publisher", "{\"repository\":\"acme/lib\"}");
    const jwt = try jwtFor(&nx, "acme/lib");
    try nx.control("/_fake/v1_creation", "{\"enabled\":true}");
    try expectStatus(try nx.call(.POST, "/api/v1/auth/oidc/exchange", try nx.fmt("{{\"jwt\":\"{s}\",\"packages\":[{{\"name\":\"ci_old\",\"version\":\"1.0.0\"}}]}}", .{jwt}), null), 200);
    try nx.control("/_fake/v1_creation", "{\"enabled\":false}");
    try expectStatus(try nx.call(.POST, "/api/v1/auth/oidc/exchange", try nx.fmt("{{\"jwt\":\"{s}\",\"packages\":[{{\"name\":\"ci_old\",\"version\":\"1.0.1\"}}]}}", .{jwt}), null), 200);
    // The single-name form for a name nobody has gets the same hint; for a name that exists it is unchanged.
    try expectCode(try nx.call(.POST, "/api/v1/auth/oidc/exchange", try nx.fmt("{{\"jwt\":\"{s}\",\"name\":\"nobody_has\",\"version\":\"1.0.0\"}}", .{jwt}), null), 403, "name_reserved");
    try expectCode(try nx.call(.POST, "/api/v1/auth/oidc/exchange", try nx.fmt("{{\"jwt\":\"{s}\",\"name\":\"ci_old\",\"version\":\"1.0.3\"}}", .{jwt}), null), 403, "oidc_not_trusted");
    const fresh = try nx.call(.POST, "/api/v1/auth/oidc/exchange", try nx.fmt("{{\"jwt\":\"{s}\",\"packages\":[{{\"name\":\"ci_old\",\"version\":\"1.0.2\"}},{{\"name\":\"ci_new\",\"version\":\"1.0.0\"}}]}}", .{jwt}), null);
    try expectCode(fresh, 403, "name_reserved");
    try std.testing.expect(nx.state.packageByName("ci_new") == null);
}

/// A JWT-shaped CI identity token whose payload's `repository` claim is `repository` (the fake checks no signature).
pub fn jwtFor(nx: *Nx, repository: []const u8) ![]const u8 {
    const payload = try nx.fmt("{{\"repository\":\"{s}\"}}", .{repository});
    const enc = std.base64.url_safe_no_pad.Encoder;
    const buf = try nx.life.allocator().alloc(u8, enc.calcSize(payload.len));
    return nx.fmt("eyJhbGciOiJub25lIn0.{s}.c2ln", .{enc.encode(buf, payload)});
}

test "a device login makes the user namespace and writes its channel, once" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    const started = try nx.call(.POST, "/api/v2/auth/device", "{\"client\":\"test\"}", null);
    try expectStatus(started, 200);
    try nx.control("/_fake/device", try nx.fmt("{{\"user_code\":\"{s}\",\"decision\":\"approve\",\"handle\":\"Dana\"}}", .{str(started.value, "user_code")}));
    const poll = try nx.fmt("{{\"device_code\":\"{s}\"}}", .{str(started.value, "device_code")});
    const approved = try nx.call(.POST, "/api/v2/auth/device/poll", poll, null);
    try expectStatus(approved, 200);
    try std.testing.expectEqualStrings("approved", str(approved.value, "status"));
    try expectStatus(try nx.call(.GET, "/api/v2/namespaces/dana", "", null), 200);
    try expectStatus(try nx.call(.GET, "/channel/dana/noarch/repodata.json", "", null), 200);
    try std.testing.expectEqualStrings("dana:user:owner:\n", try namespacesOf(&nx, str(approved.value, "token")));
    try expectStatus(try nx.call(.POST, "/api/v2/auth/device/poll", poll, null), 200);
    try std.testing.expectEqual(@as(usize, 1), nx.state.namespaces.items.len);
}

test "a CI identity writes only in namespaces whose publishers name its repository" {
    var nx: Nx = undefined;
    try nx.setup();
    defer nx.deinit();
    _ = try nx.session("alice");
    const ci = try nx.state.ciUser("acme/release");
    try std.testing.expect(ci == try nx.state.ciUser("acme/release"));
    const alice = nx.state.namespaceByName("alice").?;
    try std.testing.expectEqual(st.Right.not_member, alice.right(ci));
    try alice.publishers.append(nx.state.alloc, "acme/release");
    try std.testing.expectEqual(st.Right.write, alice.right(ci));
    try std.testing.expectEqual(st.Right.not_member, alice.right(try nx.state.ciUser("acme/other")));
    // A CI identity's login is never a namespace.
    try std.testing.expect(try nx.state.loginNamespace(ci) == null);
}
