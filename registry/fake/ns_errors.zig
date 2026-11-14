//! The error codes `/api/v2` adds (`x-mopm-errors` of spec/api/openapi-v2.yaml, the live spec of `/api/v2`), with the status,
//! message and hint written there. They are not in the catalogue of spec/api/openapi.yaml (`/api/v1`), so errors.zig (generated
//! from it) does not hold them; when the catalogue they are in is what errors.zig is generated from, these move into
//! errors.zig and this file goes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const resp = @import("resp.zig");

pub const Code = enum {
    invalid_namespace,
    not_namespace_member,
    not_namespace_owner,
    not_org_admin,
    github_account_mismatch,
    namespace_taken,
    last_owner,
    member_not_found,
    user_not_found,
    namespace_reserved,
    namespace_not_found,
};

const Entry = struct { status: std.http.Status, message: []const u8, hint: []const u8 };

pub fn entry(code: Code) Entry {
    return switch (code) {
        .invalid_namespace => .{ .status = .bad_request, .message = "'{namespace}' is not a valid namespace.", .hint = "A namespace is a GitHub login in lower case: letters, digits and single hyphens, at most 39 characters." },
        .not_namespace_member => .{ .status = .forbidden, .message = "You cannot write in '{namespace}'.", .hint = "Ask an owner of '{namespace}' to run 'mopm org add {namespace} <your mopm username>'." },
        .not_namespace_owner => .{ .status = .forbidden, .message = "You are not an owner of '{namespace}'.", .hint = "Ask an owner of '{namespace}'; 'mopm org list {namespace}' shows them." },
        .not_org_admin => .{ .status = .forbidden, .message = "You are not an active admin of the GitHub organization '{namespace}'.", .hint = "An admin of the GitHub organization runs 'mopm org create {namespace}'; an organization that restricts OAuth apps approves the mopm registry first." },
        .github_account_mismatch => .{ .status = .forbidden, .message = "The GitHub account that approved is not the one logged in to mopm.", .hint = "Approve with the GitHub account you logged in with, or run 'mopm login' with the other one." },
        .namespace_taken => .{ .status = .conflict, .message = "'{namespace}' is taken.", .hint = "Choose the namespace of another GitHub organization." },
        .last_owner => .{ .status = .conflict, .message = "'{user}' is the last owner of '{namespace}'.", .hint = "Make another member an owner first." },
        .member_not_found => .{ .status = .not_found, .message = "'{user}' is not a member of '{namespace}'.", .hint = "List the members with 'mopm org list {namespace}'." },
        .user_not_found => .{ .status = .not_found, .message = "There is no mopm user '{user}'.", .hint = "A user gets their name at their first 'mopm login'." },
        .namespace_reserved => .{ .status = .forbidden, .message = "'{namespace}' is reserved.", .hint = "Publish in an organization's namespace." },
        .namespace_not_found => .{ .status = .not_found, .message = "There is no namespace '{namespace}'.", .hint = "A user's namespace is made at their first 'mopm login'; an organization's by one of its admins." },
    };
}

/// The answer for `code`, in the error shape of the catalogue, its message and hint filled from `params`.
pub fn fail(arena: Allocator, code: Code, params: []const errors.Param) Allocator.Error!resp.Response {
    const e = entry(code);
    return resp.json(arena, e.status, .{ .@"error" = .{
        .code = @tagName(code),
        .message = try errors.fill(arena, e.message, params),
        .hint = try errors.fill(arena, e.hint, params),
    } });
}

/// `/api/v1` once names are in namespaces: creating a flat package is refused with the catalogue's `name_reserved`
/// (status and message), and this hint in place of the catalogue's.
pub const flat_creation_hint = "package names are in namespaces now; update mopm";

pub fn flatCreationRefused(arena: Allocator, name: []const u8) Allocator.Error!resp.Response {
    const e = errors.entry(.name_reserved);
    return resp.json(arena, e.status, .{ .@"error" = .{
        .code = "name_reserved",
        .message = try errors.fill(arena, e.message, &.{.{ "name", name }}),
        .hint = flat_creation_hint,
    } });
}

test "the v2 codes answer with the status, message and hint of the proposed spec" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try fail(a, .not_org_admin, &.{.{ "namespace", "komira-ai" }});
    try std.testing.expectEqual(std.http.Status.forbidden, r.status);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"not_org_admin\",\"message\":\"You are not an active admin of the GitHub organization 'komira-ai'.\",\"hint\":\"An admin of the GitHub organization runs 'mopm org create komira-ai'; an organization that restricts OAuth apps approves the mopm registry first.\"}}",
        r.body,
    );
    const last = try fail(a, .last_owner, &.{ .{ "user", "alice" }, .{ "namespace", "komira-ai" } });
    try std.testing.expectEqual(std.http.Status.conflict, last.status);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"last_owner\",\"message\":\"'alice' is the last owner of 'komira-ai'.\",\"hint\":\"Make another member an owner first.\"}}",
        last.body,
    );
    try std.testing.expectEqual(std.http.Status.conflict, (try fail(a, .namespace_taken, &.{.{ "namespace", "x" }})).status);
    try std.testing.expectEqual(std.http.Status.forbidden, (try fail(a, .github_account_mismatch, &.{})).status);
    try std.testing.expectEqual(std.http.Status.forbidden, (try fail(a, .not_namespace_owner, &.{.{ "namespace", "x" }})).status);
    try std.testing.expectEqual(std.http.Status.not_found, (try fail(a, .member_not_found, &.{ .{ "user", "u" }, .{ "namespace", "x" } })).status);
    try std.testing.expectEqual(std.http.Status.not_found, (try fail(a, .user_not_found, &.{.{ "user", "u" }})).status);
    try std.testing.expectEqual(std.http.Status.bad_request, (try fail(a, .invalid_namespace, &.{.{ "namespace", "A" }})).status);
    try std.testing.expectEqual(std.http.Status.not_found, (try fail(a, .namespace_not_found, &.{.{ "namespace", "x" }})).status);
    const flat = try flatCreationRefused(a, "json");
    try std.testing.expectEqual(std.http.Status.forbidden, flat.status);
    try std.testing.expectEqualStrings("{\"error\":{\"code\":\"name_reserved\",\"message\":\"'json' is reserved.\",\"hint\":\"package names are in namespaces now; update mopm\"}}", flat.body);
}
