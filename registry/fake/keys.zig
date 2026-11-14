//! The package a request names: a v1 name under `/api/v1`, a full name `<namespace>/<name>` under `/api/v2`
//! (spec/proposed/namespaces.md). The handlers both prefixes share check names here, so each answers with the errors of
//! the prefix it was called under; and the right to write a namespace is turned into its error here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const Ctx = api.Ctx;
const st = @import("state.zig");
const resp = @import("resp.zig");
const Response = resp.Response;
const util = @import("util.zig");
const names = @import("names.zig");
const ns_errors = @import("ns_errors.zig");

/// Why `key` cannot name a package under the request's prefix, as the answer to send, or null when it can. Under v1 a
/// name that is not normalised is `invalid_name`. Under v2 a namespace outside its grammar is `invalid_namespace`, and
/// anything else that is not a full name (no namespace, a bad name) is `invalid_name`, naming the whole key.
pub fn problem(ctx: *Ctx, key: []const u8) Allocator.Error!?Response {
    if (!ctx.v2) return if (util.isName(key)) null else try resp.fail(ctx.arena, .invalid_name, &.{.{ "name", key }});
    const f = names.split(key) orelse return try resp.fail(ctx.arena, .invalid_name, &.{.{ "name", key }});
    if (!names.isNamespace(f.namespace)) return try ns_errors.fail(ctx.arena, .invalid_namespace, &.{.{ "namespace", f.namespace }});
    if (!util.isName(f.name)) return try resp.fail(ctx.arena, .invalid_name, &.{.{ "name", key }});
    return null;
}

pub const Found = union(enum) { ok: *st.Package, fail: Response };

/// The package `key` names, or the answer to send: `problem`'s, `namespace_not_found` (v2, no such namespace), or
/// `package_not_found`.
pub fn find(ctx: *Ctx, key: []const u8) Allocator.Error!Found {
    if (try problem(ctx, key)) |r| return .{ .fail = r };
    if (names.namespaceOf(key)) |n| {
        if (ctx.state.namespaceByName(n) == null) return .{ .fail = try ns_errors.fail(ctx.arena, .namespace_not_found, &.{.{ "namespace", n }}) };
    }
    const p = ctx.state.packageByName(key) orelse return .{ .fail = try resp.fail(ctx.arena, .package_not_found, &.{.{ "name", key }}) };
    return .{ .ok = p };
}

/// The detail of `namespace_unverified` for a namespace that is frozen.
pub const frozen_detail = "no installation of the mopm registry GitHub App is bound to it";

/// The answer when `u` may not write in `n`, or null when it may: `namespace_unverified` while the namespace is frozen,
/// else `not_namespace_member`.
pub fn namespaceRefusal(ctx: *Ctx, n: *const st.Namespace, u: *const st.User) Allocator.Error!?Response {
    return switch (n.right(u)) {
        .write => null,
        .frozen => try ns_errors.fail(ctx.arena, .namespace_unverified, &.{ .{ "namespace", n.name }, .{ "detail", frozen_detail } }),
        .not_member => try ns_errors.fail(ctx.arena, .not_namespace_member, &.{.{ "namespace", n.name }}),
    };
}

/// The answer when `u` may not write `p` now, or null when it may. A package in a namespace is checked against the
/// namespace when it is used (a token stops working once its account leaves the organization); a v1 package keeps its
/// owners' rule, `not_owner`.
pub fn ownerRefusal(ctx: *Ctx, p: *const st.Package, u: *const st.User) Allocator.Error!?Response {
    if (p.namespace) |n| return namespaceRefusal(ctx, n, u);
    if (p.isOwner(u)) return null;
    return try resp.fail(ctx.arena, .not_owner, &.{.{ "name", p.name }});
}

/// Like `ownerRefusal`, but null for every v1 package: for the routes that never asked a v1 token's account to own the
/// package (a token's `packages` list is its right there).
pub fn useRefusal(ctx: *Ctx, p: *const st.Package, u: *const st.User) Allocator.Error!?Response {
    const n = p.namespace orelse return null;
    return namespaceRefusal(ctx, n, u);
}

/// The `q` of a search with `%2F` (any case) read as `/`: a client may encode the slash of `<namespace>/`.
pub fn decodeSlash(arena: Allocator, q: []const u8) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var i: usize = 0;
    while (i < q.len) {
        if (q[i] == '%' and i + 2 < q.len and q[i + 1] == '2' and (q[i + 2] == 'F' or q[i + 2] == 'f')) {
            try out.append('/');
            i += 3;
        } else {
            try out.append(q[i]);
            i += 1;
        }
    }
    return out.items;
}

test "a %2F in a query is a slash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("komira-ai/js", try decodeSlash(a, "komira-ai%2Fjs"));
    try std.testing.expectEqualStrings("komira-ai/", try decodeSlash(a, "komira-ai%2f"));
    try std.testing.expectEqualStrings("a%2", try decodeSlash(a, "a%2"));
    try std.testing.expectEqualStrings("json", try decodeSlash(a, "json"));
}
