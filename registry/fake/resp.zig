//! What a handler answers: a status, a JSON body, and the headers main.zig
//! adds (`x-mopm-request-id` always; `retry-after` when set).

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");

pub const Response = struct {
    status: std.http.Status,
    /// Empty for 204.
    body: []const u8 = "",
    retry_after: ?u32 = null,
    content_type: []const u8 = "application/json",
};

/// Seconds the fake asks a client to wait on `rate_limited` and `read_only_mode`.
pub const retry_seconds: u32 = 30;

pub fn json(arena: Allocator, status: std.http.Status, value: anytype) Allocator.Error!Response {
    var buf = std.ArrayList(u8).init(arena);
    std.json.stringify(value, .{}, buf.writer()) catch return error.OutOfMemory;
    return .{ .status = status, .body = buf.items };
}

pub fn empty(status: std.http.Status) Response {
    return .{ .status = status };
}

/// The catalogue's answer for `code`, its message and hint filled from `params`.
pub fn fail(arena: Allocator, code: errors.Code, params: []const errors.Param) Allocator.Error!Response {
    const e = errors.entry(code);
    var r = try json(arena, e.status, .{ .@"error" = .{
        .code = @tagName(code),
        .message = try errors.fill(arena, e.message, params),
        .hint = try errors.fill(arena, e.hint, params),
    } });
    if (code == .rate_limited or code == .read_only_mode) r.retry_after = retry_seconds;
    return r;
}

/// `invalid_request` with `detail`.
pub fn invalid(arena: Allocator, detail: []const u8) Allocator.Error!Response {
    return fail(arena, .invalid_request, &.{.{ "detail", detail }});
}
