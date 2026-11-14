//! The error codes `/api/v2` adds (spec/proposed/namespaces.md, "api/openapi.yaml"), with the status, message and hint
//! written there. They are not in the catalogue of spec/api/openapi.yaml yet, so errors.zig (generated from it) does not
//! hold them; when the spec moves into the catalogue, these move into errors.zig and this file goes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const resp = @import("resp.zig");

pub const Code = enum { invalid_namespace, not_namespace_member, namespace_unverified, namespace_reserved, namespace_not_found };

const Entry = struct { status: std.http.Status, message: []const u8, hint: []const u8 };

pub fn entry(code: Code) Entry {
    return switch (code) {
        .invalid_namespace => .{ .status = .bad_request, .message = "'{namespace}' is not a valid namespace.", .hint = "A namespace is a GitHub login in lower case: letters, digits and single hyphens, at most 39 characters." },
        .not_namespace_member => .{ .status = .forbidden, .message = "You cannot write in '{namespace}'.", .hint = "Ask an owner of the GitHub organization for membership." },
        .namespace_unverified => .{ .status = .forbidden, .message = "'{namespace}' cannot be verified on GitHub: {detail}.", .hint = "An owner of the organization installs the mopm registry GitHub App, then an admin runs the namespace creation again." },
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
    const r = try fail(a, .namespace_unverified, &.{ .{ "namespace", "komira-ai" }, .{ "detail", "the App is not installed" } });
    try std.testing.expectEqual(std.http.Status.forbidden, r.status);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"namespace_unverified\",\"message\":\"'komira-ai' cannot be verified on GitHub: the App is not installed.\",\"hint\":\"An owner of the organization installs the mopm registry GitHub App, then an admin runs the namespace creation again.\"}}",
        r.body,
    );
    try std.testing.expectEqual(std.http.Status.bad_request, (try fail(a, .invalid_namespace, &.{.{ "namespace", "A" }})).status);
    try std.testing.expectEqual(std.http.Status.not_found, (try fail(a, .namespace_not_found, &.{.{ "namespace", "x" }})).status);
    const flat = try flatCreationRefused(a, "json");
    try std.testing.expectEqual(std.http.Status.forbidden, flat.status);
    try std.testing.expectEqualStrings("{\"error\":{\"code\":\"name_reserved\",\"message\":\"'json' is reserved.\",\"hint\":\"package names are in namespaces now; update mopm\"}}", flat.body);
}
