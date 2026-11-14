//! Routing: `/api/v1/...` to the operation it names in spec/api/openapi.yaml,
//! `/api/v2/...` to the operation it names in spec/proposed/namespaces.md, and
//! `/_fake/...` to the test controls. A faulty fault for an operation answers
//! before its handler runs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const State = @import("state.zig").State;
const errors = @import("errors.zig");
const resp = @import("resp.zig");
const Response = resp.Response;
const util = @import("util.zig");
const auth = @import("auth.zig");
const control = @import("control.zig");
const packages = @import("packages.zig");
const publish = @import("publish.zig");
const groups = @import("groups.zig");
const files = @import("files.zig");
const ns = @import("namespaces.zig");

/// One request, with everything a handler reads.
pub const Ctx = struct {
    arena: Allocator,
    state: *State,
    method: std.http.Method,
    /// The path without the query string.
    path: []const u8,
    query: []const u8,
    body: []const u8,
    authorization: ?[]const u8,
    /// Whether the request came under `/api/v2`: package names are full names, `<namespace>/<name>`.
    v2: bool = false,

    /// `/api/v1` or `/api/v2`, the prefix the request came under.
    pub fn prefix(ctx: *const Ctx) []const u8 {
        return if (ctx.v2) prefix_v2 else prefix_v1;
    }

    /// The body as a JSON object, or null if it is absent or not an object.
    pub fn object(ctx: *Ctx) ?std.json.ObjectMap {
        if (ctx.body.len == 0) return null;
        const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, ctx.body, .{}) catch return null;
        return switch (v) {
            .object => |o| o,
            else => null,
        };
    }
};

const prefix_v1 = "/api/v1";
const prefix_v2 = "/api/v2";

const Route = struct {
    method: std.http.Method,
    /// Segments after /api/v1; `{}` matches any one segment.
    pattern: []const []const u8,
    operation: []const u8,
    handler: *const fn (*Ctx, []const []const u8) anyerror!Response,
};

const routes = [_]Route{
    .{ .method = .GET, .pattern = &.{"health"}, .operation = "getHealth", .handler = auth.getHealth },
    .{ .method = .POST, .pattern = &.{ "auth", "device" }, .operation = "startDeviceLogin", .handler = auth.startDeviceLogin },
    .{ .method = .POST, .pattern = &.{ "auth", "device", "poll" }, .operation = "pollDeviceLogin", .handler = auth.pollDeviceLogin },
    .{ .method = .POST, .pattern = &.{ "auth", "oidc", "exchange" }, .operation = "exchangeOidcToken", .handler = auth.exchangeOidcToken },
    .{ .method = .GET, .pattern = &.{"me"}, .operation = "getMe", .handler = auth.getMe },
    .{ .method = .POST, .pattern = &.{ "me", "tokens" }, .operation = "createToken", .handler = auth.createToken },
    .{ .method = .GET, .pattern = &.{ "me", "tokens" }, .operation = "listTokens", .handler = auth.listTokens },
    .{ .method = .DELETE, .pattern = &.{ "me", "tokens", "{}" }, .operation = "revokeToken", .handler = auth.revokeToken },
    .{ .method = .GET, .pattern = &.{ "me", "invitations" }, .operation = "listInvitations", .handler = packages.listInvitations },
    .{ .method = .POST, .pattern = &.{ "me", "invitations", "{}", "accept" }, .operation = "acceptInvitation", .handler = packages.acceptInvitation },
    .{ .method = .GET, .pattern = &.{"packages"}, .operation = "searchPackages", .handler = packages.searchPackages },
    .{ .method = .POST, .pattern = &.{ "packages", "{}", "claim" }, .operation = "claimPackage", .handler = packages.claimPackage },
    .{ .method = .GET, .pattern = &.{ "packages", "{}", "versions" }, .operation = "listVersions", .handler = packages.listVersions },
    .{ .method = .GET, .pattern = &.{ "packages", "{}", "owners" }, .operation = "listOwners", .handler = packages.listOwners },
    .{ .method = .PUT, .pattern = &.{ "packages", "{}", "owners" }, .operation = "inviteOwner", .handler = packages.inviteOwner },
    .{ .method = .DELETE, .pattern = &.{ "packages", "{}", "owners", "{}" }, .operation = "removeOwner", .handler = packages.removeOwner },
    .{ .method = .GET, .pattern = &.{ "packages", "{}" }, .operation = "getPackage", .handler = packages.getPackage },
    .{ .method = .GET, .pattern = &.{ "packages", "{}", "{}" }, .operation = "getVersion", .handler = publish.getVersion },
    .{ .method = .POST, .pattern = &.{ "packages", "{}", "{}", "files" }, .operation = "beginUpload", .handler = publish.beginUpload },
    .{ .method = .POST, .pattern = &.{ "packages", "{}", "{}", "publish" }, .operation = "commitPublish", .handler = publish.commitPublish },
    .{ .method = .GET, .pattern = &.{ "publishes", "{}" }, .operation = "getPublishStatus", .handler = publish.getPublishStatus },
    .{ .method = .PUT, .pattern = &.{ "packages", "{}", "{}", "yank" }, .operation = "setYanked", .handler = publish.setYanked },
    .{ .method = .POST, .pattern = &.{"groups"}, .operation = "createGroup", .handler = groups.createGroup },
    .{ .method = .GET, .pattern = &.{ "groups", "{}" }, .operation = "getGroup", .handler = groups.getGroup },
    .{ .method = .DELETE, .pattern = &.{ "groups", "{}" }, .operation = "abortGroup", .handler = groups.abortGroup },
    .{ .method = .POST, .pattern = &.{ "groups", "{}", "commit" }, .operation = "commitGroup", .handler = groups.commitGroup },
    .{ .method = .PUT, .pattern = &.{ "groups", "{}", "yank" }, .operation = "yankGroup", .handler = groups.yankGroup },
};

/// `/api/v2` (spec/proposed/namespaces.md, "api/openapi.yaml"). A package is `{namespace}/{name}`, two segments that
/// `handle` joins into one full name before matching, so the handlers v1 shares see one key. Owners, invitations and
/// claims are not here: the namespace is the owner, and `PUT /packages/{namespace}/{name}` creates.
const routes_v2 = [_]Route{
    .{ .method = .GET, .pattern = &.{"health"}, .operation = "getHealth", .handler = auth.getHealth },
    .{ .method = .POST, .pattern = &.{ "auth", "device" }, .operation = "startDeviceLogin", .handler = auth.startDeviceLogin },
    .{ .method = .POST, .pattern = &.{ "auth", "device", "poll" }, .operation = "pollDeviceLogin", .handler = auth.pollDeviceLogin },
    .{ .method = .POST, .pattern = &.{ "auth", "oidc", "exchange" }, .operation = "exchangeOidcToken", .handler = ns.exchangeOidcToken },
    .{ .method = .GET, .pattern = &.{"me"}, .operation = "getMe", .handler = ns.getMe },
    .{ .method = .POST, .pattern = &.{ "me", "tokens" }, .operation = "createToken", .handler = auth.createToken },
    .{ .method = .GET, .pattern = &.{ "me", "tokens" }, .operation = "listTokens", .handler = auth.listTokens },
    .{ .method = .DELETE, .pattern = &.{ "me", "tokens", "{}" }, .operation = "revokeToken", .handler = auth.revokeToken },
    .{ .method = .POST, .pattern = &.{"namespaces"}, .operation = "createNamespace", .handler = ns.createNamespace },
    .{ .method = .GET, .pattern = &.{ "namespaces", "{}" }, .operation = "getNamespace", .handler = ns.getNamespace },
    .{ .method = .GET, .pattern = &.{"packages"}, .operation = "searchPackages", .handler = packages.searchPackages },
    .{ .method = .PUT, .pattern = &.{ "packages", "{}" }, .operation = "createPackage", .handler = ns.createPackage },
    .{ .method = .GET, .pattern = &.{ "packages", "{}", "versions" }, .operation = "listVersions", .handler = packages.listVersions },
    .{ .method = .GET, .pattern = &.{ "packages", "{}" }, .operation = "getPackage", .handler = ns.getPackage },
    .{ .method = .GET, .pattern = &.{ "packages", "{}", "{}" }, .operation = "getVersion", .handler = publish.getVersion },
    .{ .method = .POST, .pattern = &.{ "packages", "{}", "{}", "files" }, .operation = "beginUpload", .handler = publish.beginUpload },
    .{ .method = .POST, .pattern = &.{ "packages", "{}", "{}", "publish" }, .operation = "commitPublish", .handler = publish.commitPublish },
    .{ .method = .GET, .pattern = &.{ "publishes", "{}" }, .operation = "getPublishStatus", .handler = publish.getPublishStatus },
    .{ .method = .PUT, .pattern = &.{ "packages", "{}", "{}", "yank" }, .operation = "setYanked", .handler = publish.setYanked },
    .{ .method = .POST, .pattern = &.{"groups"}, .operation = "createGroup", .handler = groups.createGroup },
    .{ .method = .GET, .pattern = &.{ "groups", "{}" }, .operation = "getGroup", .handler = groups.getGroup },
    .{ .method = .DELETE, .pattern = &.{ "groups", "{}" }, .operation = "abortGroup", .handler = groups.abortGroup },
    .{ .method = .POST, .pattern = &.{ "groups", "{}", "commit" }, .operation = "commitGroup", .handler = groups.commitGroup },
    .{ .method = .PUT, .pattern = &.{ "groups", "{}", "yank" }, .operation = "yankGroup", .handler = groups.yankGroup },
};

/// The segments of a `/api/v2` path, with the `{namespace}` and `{name}` after `packages` joined into one segment,
/// `<namespace>/<name>`. `packages/{namespace}` with no name gives no segments, so it matches no route.
fn segmentsV2(arena: Allocator, rest: []const u8) Allocator.Error![]const []const u8 {
    var segs = std.ArrayList([]const u8).init(arena);
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |seg| try segs.append(seg);
    const items = segs.items;
    if (items.len < 2 or !std.mem.eql(u8, items[0], "packages")) return items;
    if (items.len == 2) return &.{};
    const joined = try std.fmt.allocPrint(arena, "{s}/{s}", .{ items[1], items[2] });
    var out = std.ArrayList([]const u8).init(arena);
    try out.appendSlice(&.{ items[0], joined });
    try out.appendSlice(items[3..]);
    return out.items;
}

/// The `{}` segments of `segs` if it matches `pattern`, else null.
fn match(arena: Allocator, pattern: []const []const u8, segs: []const []const u8) Allocator.Error!?[]const []const u8 {
    if (pattern.len != segs.len) return null;
    var params = std.ArrayList([]const u8).init(arena);
    for (pattern, segs) |p, s| {
        if (std.mem.eql(u8, p, "{}")) {
            if (s.len == 0) return null;
            try params.append(s);
        } else if (!std.mem.eql(u8, p, s)) return null;
    }
    return try params.toOwnedSlice();
}

pub fn handle(ctx: *Ctx) anyerror!Response {
    const upload_prefix = "/_fake/upload/";
    const is_control = std.mem.startsWith(u8, ctx.path, "/_fake/") and !std.mem.startsWith(u8, ctx.path, upload_prefix);
    if (is_control) return control.handle(ctx);
    ctx.state.api_requests += 1;
    if (std.mem.startsWith(u8, ctx.path, "/channel/") or std.mem.startsWith(u8, ctx.path, "/index/")) return files.serve(ctx);
    if (std.mem.startsWith(u8, ctx.path, upload_prefix)) return publish.uploadBytes(ctx, ctx.path[upload_prefix.len..]);
    ctx.v2 = std.mem.startsWith(u8, ctx.path, prefix_v2 ++ "/");
    if (!ctx.v2 and !std.mem.startsWith(u8, ctx.path, prefix_v1 ++ "/")) {
        return resp.fail(ctx.arena, .route_not_found, &.{});
    }
    const rest = ctx.path[prefix_v1.len + 1 ..];
    var segs = std.ArrayList([]const u8).init(ctx.arena);
    if (ctx.v2) {
        try segs.appendSlice(try segmentsV2(ctx.arena, rest));
    } else {
        var it = std.mem.splitScalar(u8, rest, '/');
        while (it.next()) |s| try segs.append(s);
    }
    // A path can match several patterns (owners vs a version); the routes
    // are listed so that literal segments win, and methods disambiguate.
    const table: []const Route = if (ctx.v2) &routes_v2 else &routes;
    for (table) |r| {
        const params = (try match(ctx.arena, r.pattern, segs.items)) orelse continue;
        if (!literalWins(r, segs.items)) continue;
        if (r.method != ctx.method) continue;
        if (ctx.state.takeFault(r.operation)) |code| return injectedFault(ctx, code);
        return r.handler(ctx, params);
    }
    // An unknown path, or a known path with a method it does not take.
    return resp.fail(ctx.arena, .route_not_found, &.{});
}

/// `/packages/{name}/{version}` must not swallow `/packages/x/owners` and the
/// like: a `{}` segment in the version position may not be a literal that
/// another route uses there.
fn literalWins(r: Route, segs: []const []const u8) bool {
    if (r.pattern.len < 3 or !std.mem.eql(u8, r.pattern[0], "packages")) return true;
    if (!std.mem.eql(u8, r.pattern[2], "{}")) return true;
    const reserved = [_][]const u8{ "claim", "versions", "owners" };
    for (reserved) |w| {
        if (std.mem.eql(u8, segs[2], w)) return false;
    }
    return true;
}

fn injectedFault(ctx: *Ctx, code: errors.Code) anyerror!Response {
    return switch (code) {
        .rate_limited => resp.fail(ctx.arena, code, &.{.{ "retry_after", std.fmt.comptimePrint("{d}", .{resp.retry_seconds}) }}),
        .invalid_request, .upload_invalid, .oidc_token_invalid => resp.fail(ctx.arena, code, &.{.{ "detail", "faulty by the fake" }}),
        else => resp.fail(ctx.arena, code, &.{}),
    };
}

/// The value of query parameter `key`, percent-decoding not needed for the
/// values the API takes (names, cursors, numbers).
pub fn queryParam(ctx: *Ctx, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, ctx.query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

test "routes match by segments, and literals beat the version slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = (try match(a, &.{ "me", "tokens", "{}" }, &.{ "me", "tokens", "tok-1" })).?;
    try std.testing.expectEqualStrings("tok-1", p[0]);
    try std.testing.expect((try match(a, &.{ "me", "tokens" }, &.{ "me", "tokens", "x" })) == null);
    const version_route = routes[17];
    try std.testing.expectEqualStrings("getVersion", version_route.operation);
    try std.testing.expect(!literalWins(version_route, &.{ "packages", "json", "owners" }));
    try std.testing.expect(literalWins(version_route, &.{ "packages", "json", "1.0" }));
}

test "v2 joins the namespace and the name of a package path into one segment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const segs = try segmentsV2(a, "packages/komira-ai/json/0.1.0/files");
    try std.testing.expectEqual(@as(usize, 4), segs.len);
    try std.testing.expectEqualStrings("komira-ai/json", segs[1]);
    try std.testing.expectEqualStrings("0.1.0", segs[2]);
    try std.testing.expectEqualStrings("files", segs[3]);
    try std.testing.expectEqual(@as(usize, 0), (try segmentsV2(a, "packages/komira-ai")).len);
    try std.testing.expectEqual(@as(usize, 1), (try segmentsV2(a, "packages")).len);
    try std.testing.expectEqual(@as(usize, 2), (try segmentsV2(a, "me/tokens")).len);
    try std.testing.expectEqualStrings("komira-ai/json", (try segmentsV2(a, "packages/komira-ai/json"))[1]);
}
